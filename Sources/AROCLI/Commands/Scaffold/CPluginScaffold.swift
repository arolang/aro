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
            "     — add ARO_ACTION / ARO_QUALIFIER handlers",
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
        CFLAGS   = -O2 -fPIC -Wall -Wextra -Iinclude
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

    /// Internal (not private) so tests can assert the generated source without
    /// running `generate()`, which downloads the SDK header from the network.
    func pluginSource(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        let langComment = isCpp ? "C++ plugin" : "C plugin"
        let include     = isCpp ? "#include <cctype>\n#include <cstdlib>\n#include <cstring>" : "#include <ctype.h>\n#include <stdlib.h>\n#include <string.h>"

        var actionsBlock = ""
        if options.includeActions {
            actionsBlock = """


            /* ── Actions ───────────────────────────────────────────────────────────── */

            /*
             * \(handle).Example  —  an example action
             *
             * ARO usage:
             *   \(handle).Example the <result> from <source>.
             */
            ARO_ACTION("example", "own", "with,from") {
                /* TODO: Implement your action logic */
                aro_output_string(ctx, "result", "ok");
                return aro_ok(ctx);
            }
            """
        }

        var qualifiersBlock = ""
        if options.includeQualifiers {
            qualifiersBlock = """


            /* ── Qualifiers ────────────────────────────────────────────────────────── */

            /*
             * \(handle).example  —  uppercases a string (example qualifier)
             *
             * ARO usage:
             *   Compute the <loud: \(handle).example> from the <text>.
             */
            ARO_QUALIFIER("example", "String", "Uppercases a string (example qualifier)") {
                const char* value = aro_qualifier_string(ctx);
                if (!value)
                    return aro_error(ctx, ARO_ERR_INVALID_INPUT,
                                     "example requires a string");

                size_t len = strlen(value);
                char* upper = (char*)malloc(len + 1);
                if (!upper)
                    return aro_error(ctx, ARO_ERR_RESOURCE_EXHAUSTED, "out of memory");
                for (size_t i = 0; i < len; i++)
                    upper[i] = (char)toupper((unsigned char)value[i]);
                upper[len] = '\\0';

                const char* result = aro_qualifier_result_string(ctx, upper);
                free(upper);
                return result;
            }
            """
        }

        return """
        /**
         * ARO Plugin — \(name) (\(langComment))
         *
         * Written with the ARO C Plugin SDK macro syntax. The SDK implements
         * the full ARO native plugin C ABI (aro_plugin_info, aro_plugin_execute,
         * aro_plugin_qualifier, aro_plugin_free, aro_plugin_init,
         * aro_plugin_shutdown) — you only write ARO_ACTION / ARO_QUALIFIER
         * handlers.
         *
         * SDK docs: https://github.com/arolang/aro-plugin-sdk-c
         */

        \(include)

        #define ARO_PLUGIN_SDK_IMPLEMENTATION
        #include "aro_plugin_sdk.h"

        /* ── Plugin identity ───────────────────────────────────────────────────── */

        ARO_PLUGIN("\(name)", "1.0.0")
        ARO_HANDLE("\(handle)")

        /* ── Lifecycle ─────────────────────────────────────────────────────────── */

        ARO_INIT() {
            /* Allocate long-lived resources here. */
        }

        ARO_SHUTDOWN() {
            /* Release resources here. */
        }\(actionsBlock)\(qualifiersBlock)
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
