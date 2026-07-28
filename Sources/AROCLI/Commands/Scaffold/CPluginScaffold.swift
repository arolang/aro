// ============================================================
// CPluginScaffold.swift
// ARO CLI - C and C++ plugin scaffolding
// ============================================================

import Foundation

/// Shared behaviour for the C and C++ scaffolds, which differ only by the
/// `isCpp` flag (source extension, compiler, SDK headers, link flags).
protocol CFamilyScaffold: PluginScaffold {
    var isCpp: Bool { get }
}

extension CFamilyScaffold {
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let makeURL = pluginDir.appendingPathComponent("Makefile")
        try write(content: makefile(options: options), to: makeURL)
        created.append(relativePath(makeURL, to: pluginDir))

        let srcExt = isCpp ? "cpp" : "c"
        let srcURL = pluginDir.appendingPathComponent("src/plugin.\(srcExt)")
        try write(content: pluginSource(options: options), to: srcURL)
        created.append(relativePath(srcURL, to: pluginDir))

        // Download the SDK header(s) from the repo.
        let includeDir = pluginDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        let headers = isCpp ? ["aro_plugin_sdk.h", "aro_plugin_sdk.hpp"] : ["aro_plugin_sdk.h"]
        for header in headers {
            let sdkURL = "https://raw.githubusercontent.com/arolang/aro-plugin-sdk-c/main/include/\(header)"
            if let url = URL(string: sdkURL),
               let data = try? Data(contentsOf: url) {
                let headerPath = includeDir.appendingPathComponent(header)
                try data.write(to: headerPath)
                created.append(relativePath(headerPath, to: pluginDir))
            }
        }

        try appendHybridFeatures(options: options, pluginDir: pluginDir, into: &created)
        return created
    }

    func nextSteps(options: ScaffoldOptions) -> [String] {
        let name = options.pluginName
        let ext = isCpp ? "cpp" : "c"
        return [
            "  1. Edit Plugins/\(name)/src/plugin.\(ext)",
            "     — implement your actions in aro_plugin_execute()",
            "",
            "  2. Build the plugin dynamic library:",
            "     cd Plugins/\(name) && make",
            "",
            "  3. Reference the plugin in your .aro application and run:",
            "     aro run .",
        ]
    }

    // MARK: - Templates

    private func pluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        let libName = name.replacingOccurrences(of: "-", with: "_")
        let compiler = isCpp ? "clang++" : "clang"
        let flags = isCpp ? "[-O2, -fPIC, -shared, -lstdc++]" : "[-O2, -fPIC, -shared]"
        let langLabel = isCpp ? "C++" : "C"
        var provides = """
        - type: c-plugin
          path: src/
          handler: \(handle.lowercased())
          build:
            compiler: \(compiler)
            flags: \(flags)
            output: lib\(libName)_plugin.dylib
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A \(langLabel) plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func makefile(options: ScaffoldOptions) -> String {
        let name    = options.pluginName
        let libName = name.replacingOccurrences(of: "-", with: "_")
        let compiler = isCpp ? "CXX = clang++" : "CC = clang"
        let compilerVar = isCpp ? "$(CXX)" : "$(CC)"
        let extraFlags = isCpp ? " -lstdc++" : ""
        let srcExt = isCpp ? "cpp" : "c"
        return """
        # Makefile — \(name) plugin
        # Builds a shared library for the ARO runtime.
        #
        # Usage:
        #   make          # Build for current platform
        #   make clean    # Remove build artifacts

        \(compiler)
        CFLAGS   = -O2 -fPIC -Wall -Wextra
        SRC_DIR  = src
        SRC      = $(SRC_DIR)/plugin.\(srcExt)
        LIB_NAME = lib\(libName)_plugin

        # Detect platform
        UNAME := $(shell uname -s)
        ifeq ($(UNAME), Darwin)
            SHARED_FLAGS = -dynamiclib -undefined dynamic_lookup
            TARGET       = $(LIB_NAME).dylib
        else ifeq ($(UNAME), Linux)
            SHARED_FLAGS = -shared
            TARGET       = $(LIB_NAME).so
        else
            SHARED_FLAGS = -shared
            TARGET       = $(LIB_NAME).dll
        endif

        .PHONY: all clean

        all: $(TARGET)

        $(TARGET): $(SRC)
        \t\(compilerVar) $(CFLAGS) $(SHARED_FLAGS)\(extraFlags) -o $@ $<

        clean:
        \trm -f $(LIB_NAME).dylib $(LIB_NAME).so $(LIB_NAME).dll
        """
    }

    private func pluginSource(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        let langComment = isCpp ? "C++ plugin" : "C plugin"
        let externC     = isCpp ? "extern \"C\" {\n\n" : ""
        let externCEnd  = isCpp ? "\n} // extern \"C\"\n" : ""
        let include     = isCpp ? "#include <cstdio>\n#include <cstdlib>\n#include <cstring>" : "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>"

        return """
        /**
         * ARO Plugin — \(name) (\(langComment), ARO-0073 ABI)
         *
         * Implements the ARO native plugin C ABI:
         *   char* aro_plugin_info(void)
         *   void  aro_plugin_init(void)
         *   void  aro_plugin_shutdown(void)
         *   char* aro_plugin_execute(const char* action, const char* input_json)
         *   void  aro_plugin_free(char* ptr)
         */

        \(include)
        \(externC)
        /* ── ARO-0073 ABI ──────────────────────────────────────────────────────── */

        /**
         * aro_plugin_info — REQUIRED
         * Returns a heap-allocated JSON string with plugin metadata.
         * Caller must free via aro_plugin_free().
         */
        char* aro_plugin_info(void) {
            const char* info =
                "{"
                    "\\"name\\":\\"\(name)\\","
                    "\\"version\\":\\"1.0.0\\","
                    "\\"handle\\":\\"\(handle)\\","
                    "\\"abi\\":\\"ARO-0073\\","
                    "\\"actions\\":["
                        "{"
                            "\\"name\\":\\"Example\\","
                            "\\"verbs\\":[\\"example\\"],"
                            "\\"role\\":\\"own\\","
                            "\\"prepositions\\":[\\"with\\",\\"from\\"]"
                        "}"
                    "]"
                "}";
            char* result = malloc(strlen(info) + 1);
            if (result) strcpy(result, info);
            return result;
        }

        /** aro_plugin_init — lifecycle hook, called once after dlopen(). */
        void aro_plugin_init(void) {
            /* Allocate long-lived resources here. */
        }

        /** aro_plugin_shutdown — lifecycle hook, called once before dlclose(). */
        void aro_plugin_shutdown(void) {
            /* Release resources here. */
        }

        /**
         * aro_plugin_execute — dispatch an action.
         *
         * input_json conforms to ARO-0073:
         *   { "result":{...}, "source":{...}, "preposition":"...",
         *     "data":<primary>, "_with":{...}, "_context":{...} }
         */
        char* aro_plugin_execute(const char* action, const char* input_json) {
            const size_t BUF = 512;
            char* result = malloc(BUF);
            if (!result) return NULL;

            if (strcmp(action, "example") == 0) {
                /* TODO: Implement example action */
                snprintf(result, BUF, "{\\"result\\":\\"ok\\",\\"action\\":\\"%s\\"}", action);
            } else {
                snprintf(result, BUF, "{\\"error\\":\\"Unknown action: %s\\"}", action);
            }

            return result;
        }

        /**
         * aro_plugin_free — REQUIRED
         * Frees memory allocated by this plugin and returned to the runtime.
         */
        void aro_plugin_free(char* ptr) {
            free(ptr);
        }
        \(externCEnd)
        """
    }
}

/// Scaffolds a C plugin (plugin.yaml, Makefile, src/plugin.c, SDK header).
struct CPluginScaffold: CFamilyScaffold {
    let isCpp = false
}

/// Scaffolds a C++ plugin (plugin.yaml, Makefile, src/plugin.cpp, SDK headers).
struct CppPluginScaffold: CFamilyScaffold {
    let isCpp = true
}
