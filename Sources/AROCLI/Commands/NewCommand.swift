// ============================================================
// NewCommand.swift
// ARO CLI - Scaffold New Plugin Command
// ============================================================

import ArgumentParser
import Foundation

// MARK: - NewCommand (parent)

/// Command group for scaffolding new ARO project components
struct NewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Scaffold a new ARO plugin or component",
        discussion: """
            Generates starter project structure for a new ARO plugin.

            Example:
              aro new plugin --name my-csv --lang rust --actions --qualifiers
              aro new plugin my-greeting --lang swift
              aro new plugin --name my-workflows --lang aro
              aro new plugin --name my-templates --lang aro --templates
            """,
        subcommands: [
            NewPluginCommand.self,
        ],
        defaultSubcommand: NewPluginCommand.self
    )
}

// MARK: - Language enum

enum PluginLanguage: String, ExpressibleByArgument, CaseIterable {
    case swift
    case rust
    case c
    case cpp
    case python
    case aro

    var displayName: String {
        switch self {
        case .swift:  return "Swift"
        case .rust:   return "Rust"
        case .c:      return "C"
        case .cpp:    return "C++"
        case .python: return "Python"
        case .aro:    return "ARO"
        }
    }
}

// MARK: - NewPluginCommand

/// Scaffold a new plugin in the given language
struct NewPluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Scaffold a new ARO plugin",
        discussion: """
            Generates a plugin skeleton inside Plugins/<name>/ in the current directory.

            Example:
              aro new plugin --name my-csv --lang rust --actions --qualifiers
              aro new plugin my-greeting --lang swift
              aro new plugin --name my-workflows --lang aro
              aro new plugin --name my-templates --lang aro --templates
            """
    )

    // MARK: - Arguments & Options

    @Argument(help: "Plugin name in kebab-case (alternative to --name)")
    var positionalName: String?

    @Option(name: .long, help: "Plugin name in kebab-case")
    var name: String?

    @Option(name: .long, help: "Language: swift, rust, c, cpp, python, aro")
    var lang: PluginLanguage

    @Option(name: .long, help: "PascalCase namespace handle (default: derived from name)")
    var handle: String?

    @Flag(name: .long, help: "Include action scaffolding (default: true when no other flags are set)")
    var actions: Bool = false

    @Flag(name: .long, help: "Include qualifier scaffolding")
    var qualifiers: Bool = false

    @Flag(name: .long, help: "Include service scaffolding")
    var services: Bool = false

    @Flag(name: .long, help: "Include system object scaffolding")
    var systemObjects: Bool = false

    @Flag(name: .long, help: "Include event handler scaffolding")
    var events: Bool = false

    @Flag(name: .long, help: "Include aro-templates provider")
    var templates: Bool = false

    @Flag(name: .long, help: "Include both native code and aro-files providers")
    var hybrid: Bool = false

    @Option(name: .shortAndLong, help: "Output directory (default: current directory)")
    var directory: String?

    // MARK: - Run

    func run() throws {
        // Resolve the plugin name from positional or --name
        guard let pluginName = positionalName ?? name, !pluginName.isEmpty else {
            print("Error: A plugin name is required (use --name or provide it as an argument).")
            throw ExitCode.failure
        }

        // Validate kebab-case
        let validNameChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard pluginName.unicodeScalars.allSatisfy({ validNameChars.contains($0) }),
              pluginName.first != "-", pluginName.last != "-" else {
            print("Error: Plugin name must be in kebab-case (e.g. my-csv, greeting-plugin).")
            throw ExitCode.failure
        }

        // Derive handle from name if not provided
        let resolvedHandle = handle ?? deriveHandle(from: pluginName)

        // Determine which features to scaffold
        // If none of the feature flags are set, default to --actions
        let includeActions = actions || (!qualifiers && !services && !systemObjects && !events && !templates)
        let includeQualifiers = qualifiers
        let includeServices = services
        let includeSystemObjects = systemObjects
        let includeEvents = events
        let includeTemplates = templates
        let includeHybrid = hybrid

        // Resolve output directory
        let baseDir = directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        let pluginsDir = baseDir.appendingPathComponent("Plugins", isDirectory: true)
        let pluginDir  = pluginsDir.appendingPathComponent(pluginName, isDirectory: true)

        // Check the output directory does not already exist
        if FileManager.default.fileExists(atPath: pluginDir.path) {
            print("Error: Directory already exists: \(pluginDir.path)")
            throw ExitCode.failure
        }

        let options = ScaffoldOptions(
            pluginName:          pluginName,
            handle:              resolvedHandle,
            language:            lang,
            includeActions:      includeActions,
            includeQualifiers:   includeQualifiers,
            includeServices:     includeServices,
            includeSystemObjects: includeSystemObjects,
            includeEvents:       includeEvents,
            includeTemplates:    includeTemplates,
            includeHybrid:       includeHybrid
        )

        print("Scaffolding \(lang.displayName) plugin \"\(pluginName)\" (handle: \(resolvedHandle))...")
        print("")

        do {
            let files = try generateScaffold(options: options, pluginDir: pluginDir)

            for file in files {
                print("  + \(file)")
            }

            print("")
            print("Plugin created at Plugins/\(pluginName)/")
            print("")
            printNextSteps(options: options, pluginDir: pluginDir)

        } catch {
            print("Error: Failed to scaffold plugin: \(error)")
            throw ExitCode.failure
        }
    }

    // MARK: - Handle Derivation

    /// Converts a kebab-case name to PascalCase for use as a handle.
    /// Example: "my-csv-parser" → "MyCsvParser"
    private func deriveHandle(from name: String) -> String {
        name.split(separator: "-")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined()
    }

    // MARK: - Scaffold Generation

    private func generateScaffold(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var createdFiles: [String] = []

        // Create plugin directory
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)

        switch options.language {
        case .swift:
            createdFiles += try scaffoldSwift(options: options, pluginDir: pluginDir)
        case .rust:
            createdFiles += try scaffoldRust(options: options, pluginDir: pluginDir)
        case .c:
            createdFiles += try scaffoldC(options: options, pluginDir: pluginDir)
        case .cpp:
            createdFiles += try scaffoldCpp(options: options, pluginDir: pluginDir)
        case .python:
            createdFiles += try scaffoldPython(options: options, pluginDir: pluginDir)
        case .aro:
            createdFiles += try scaffoldARO(options: options, pluginDir: pluginDir)
        }

        return createdFiles
    }

    // MARK: - Write Helper

    private func write(content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func relativePath(_ url: URL, to base: URL) -> String {
        // Return the path relative to the Plugins/ parent
        let pluginsDirPath = base.deletingLastPathComponent().path
        let fullPath = url.path
        if fullPath.hasPrefix(pluginsDirPath + "/") {
            return "Plugins/" + String(fullPath.dropFirst(pluginsDirPath.count + 1))
        }
        return fullPath
    }

    // MARK: - Swift Scaffold

    private func scaffoldSwift(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []
        let handle = options.handle

        // plugin.yaml
        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: swiftPluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        // Package.swift
        let pkgURL = pluginDir.appendingPathComponent("Package.swift")
        try write(content: swiftPackageSwift(options: options), to: pkgURL)
        created.append(relativePath(pkgURL, to: pluginDir))

        // Sources/<Handle>Plugin.swift
        let sourcesDir = pluginDir.appendingPathComponent("Sources", isDirectory: true)
        let swiftURL   = sourcesDir.appendingPathComponent("\(handle)Plugin.swift")
        try write(content: swiftPluginSource(options: options), to: swiftURL)
        created.append(relativePath(swiftURL, to: pluginDir))

        // aro-files features directory for hybrid mode
        if options.includeHybrid {
            let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
            try write(content: aroFeaturesExample(options: options), to: featuresURL)
            created.append(relativePath(featuresURL, to: pluginDir))
        }

        return created
    }

    private func swiftPluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        var provides = """
        - type: swift-plugin
          path: Sources/
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A Swift plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        build:
          swift:
            minimum-version: '6.2'
            targets:
            - name: \(handle)Plugin
              path: Sources/
        """
    }

    private func swiftPackageSwift(options: ScaffoldOptions) -> String {
        let handle = options.handle
        return """
        // swift-tools-version: 6.2
        // Package.swift — \(handle)Plugin
        //
        // Built as a dynamic library so the ARO runtime can dlopen() it.
        // Replace the AROPluginSDK URL and version with your actual dependency.

        import PackageDescription

        let package = Package(
            name: "\(handle)Plugin",
            platforms: [
                .macOS(.v14),
            ],
            products: [
                .library(
                    name: "\(handle)Plugin",
                    type: .dynamic,
                    targets: ["\(handle)Plugin"]
                ),
            ],
            dependencies: [
                .package(url: "https://github.com/arolang/aro-plugin-sdk-swift.git", branch: "main"),
            ],
            targets: [
                .target(
                    name: "\(handle)Plugin",
                    dependencies: [
                        .product(name: "AROPluginSDK", package: "aro-plugin-sdk-swift"),
                    ],
                    path: "Sources"
                ),
            ]
        )
        """
    }

    private func swiftPluginSource(options: ScaffoldOptions) -> String {
        let handle = options.handle
        let name   = options.pluginName

        var actionLines = ""
        if options.includeActions {
            actionLines = """

                    let exampleAction: NSDictionary = [
                        "name":         "Example",
                        "role":         "own",
                        "verbs":        ["\(handle.lowercased())-example"] as NSArray,
                        "prepositions": ["with", "from"]                   as NSArray,
                        "description":  "An example action provided by \(name)."
                    ]
                    actions.append(exampleAction)
            """
        }

        var qualifierLines = ""
        if options.includeQualifiers {
            qualifierLines = """

                    let exampleQualifier: NSDictionary = [
                        "name":        "example",
                        "description": "An example qualifier provided by \(name).",
                        "input":       "Any",
                        "output":      "Any"
                    ]
                    qualifiers.append(exampleQualifier)
            """
        }

        var serviceLines = ""
        if options.includeServices {
            serviceLines = """

                    let exampleService: NSDictionary = [
                        "name": "\(handle)Service",
                        "description": "An example service provided by \(name)."
                    ]
                    services.append(exampleService)
            """
        }

        let executeBody = buildSwiftExecuteBody(options: options)

        return """
        // ============================================================
        // \(handle)Plugin.swift
        // ARO Plugin - \(name) (ARO-0073 ABI)
        // ============================================================

        import Foundation

        public struct \(handle)Plugin {
            public static let name    = "\(name)"
            public static let version = "1.0.0"
        }

        // MARK: - C ABI Interface

        @_cdecl("aro_plugin_info")
        public func aroPluginInfo() -> UnsafeMutablePointer<CChar>? {
            var actions:    [NSDictionary] = []
            var qualifiers: [NSDictionary] = []
            var services:   [NSDictionary] = []
        \(actionLines)
        \(qualifierLines)
        \(serviceLines)
            var info: [String: Any] = [
                "name":        "\(name)",
                "version":     "1.0.0",
                "handle":      "\(handle)",
                "description": "A Swift plugin that provides \(name) functionality.",
                "abi":         "ARO-0073",
            ]
            if !actions.isEmpty    { info["actions"]    = actions    as NSArray }
            if !qualifiers.isEmpty { info["qualifiers"] = qualifiers as NSArray }
            if !services.isEmpty   { info["services"]   = services   as NSArray }

            guard let jsonData   = try? JSONSerialization.data(withJSONObject: info as NSDictionary),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return nil
            }
            return strdup(jsonString)
        }

        @_cdecl("aro_plugin_init")
        public func aroPluginInit() {
            // Allocate long-lived resources here (thread pools, connections, caches).
        }

        @_cdecl("aro_plugin_shutdown")
        public func aroPluginShutdown() {
            // Release resources acquired in aroPluginInit.
        }

        @_cdecl("aro_plugin_execute")
        public func aroPluginExecute(
            action:    UnsafePointer<CChar>?,
            inputJson: UnsafePointer<CChar>?
        ) -> UnsafeMutablePointer<CChar>? {
            guard let action    = action.map({ String(cString: $0) }),
                  let inputJson = inputJson.map({ String(cString: $0) }) else {
                return strdup(#"{"error":"Invalid input"}"#)
            }

            guard let jsonData = inputJson.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return strdup(#"{"error":"Invalid JSON input"}"#)
            }

            let withArgs    = envelope["_with"] as? [String: Any] ?? [:]
            let primaryData = envelope["data"]

        \(executeBody)
        }

        @_cdecl("aro_plugin_free")
        public func aroPluginFree(ptr: UnsafeMutablePointer<CChar>?) {
            guard let ptr else { return }
            free(ptr)
        }

        // MARK: - Helpers

        private func jsonResult(_ dict: [String: Any]) -> UnsafeMutablePointer<CChar>? {
            guard let data   = try? JSONSerialization.data(withJSONObject: dict),
                  let string = String(data: data, encoding: .utf8) else {
                return strdup(#"{"error":"Serialization failed"}"#)
            }
            return strdup(string)
        }
        """
    }

    private func buildSwiftExecuteBody(options: ScaffoldOptions) -> String {
        var cases: [String] = []
        if options.includeActions {
            cases.append("""
                    case "\(options.handle.lowercased())-example":
                        // TODO: Implement example action
                        let result: [String: Any] = ["result": "ok", "action": action]
                        return jsonResult(result)
            """)
        }
        if options.includeQualifiers {
            cases.append("""
                    case "example":
                        // TODO: Implement example qualifier transformation
                        return strdup(inputJson)
            """)
        }
        let switchBody = cases.isEmpty
            ? "            // No actions registered."
            : cases.joined(separator: "\n")

        return """
                switch action.lowercased() {
        \(switchBody)
                default:
                    return strdup("{\\\"error\\\":\\\"Unknown action: \\\\(action)\\\"}")
                }
        """
    }

    // MARK: - Rust Scaffold

    private func scaffoldRust(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        // plugin.yaml
        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: rustPluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        // Cargo.toml
        let cargoURL = pluginDir.appendingPathComponent("Cargo.toml")
        try write(content: rustCargoToml(options: options), to: cargoURL)
        created.append(relativePath(cargoURL, to: pluginDir))

        // src/lib.rs
        let libURL = pluginDir.appendingPathComponent("src/lib.rs")
        try write(content: rustLibRs(options: options), to: libURL)
        created.append(relativePath(libURL, to: pluginDir))

        if options.includeHybrid {
            let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
            try write(content: aroFeaturesExample(options: options), to: featuresURL)
            created.append(relativePath(featuresURL, to: pluginDir))
        }

        return created
    }

    private func rustPluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        let crateName = name.replacingOccurrences(of: "-", with: "_")
        var provides = """
        - type: rust-plugin
          path: src/
          build:
            cargo-target: release
            output: target/release/lib\(crateName).dylib
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A Rust plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func rustCargoToml(options: ScaffoldOptions) -> String {
        let name      = options.pluginName
        let crateName = name.replacingOccurrences(of: "-", with: "_")
        return """
        [package]
        name = "\(crateName)"
        version = "1.0.0"
        edition = "2021"
        description = "ARO plugin: \(name)"
        license = "MIT"

        [lib]
        name = "\(crateName)"
        crate-type = ["cdylib"]

        [dependencies]
        serde_json = "1.0"
        aro-plugin-sdk = { git = "https://github.com/arolang/aro-plugin-sdk-rust.git", branch = "main" }

        [profile.release]
        lto = true
        opt-level = "z"
        panic = "abort"
        """
    }

    private func rustLibRs(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        // Build the optional fields for plugin info JSON (as Rust literal string fragments)
        var extraInfoFields = ""
        if options.includeActions {
            extraInfoFields += #","actions":[{"name":"Example","verbs":["example"],"role":"own","prepositions":["with","from"],"description":"An example action."}]"#
        }
        if options.includeQualifiers {
            extraInfoFields += #","qualifiers":[{"name":"example","description":"An example qualifier.","input":"Any","output":"Any"}]"#
        }

        // Build match arms for aro_plugin_execute
        var matchArms = ""
        if options.includeActions {
            matchArms += """
                        "example" => r#"{"result":"ok"}"#.to_string(),
            """
        }

        // Produce the Rust literal for the static info JSON string
        let infoJsonLiteral = #"{"name":""# + name + #"","version":"1.0.0","handle":""# + handle + #"","abi":"ARO-0073""# + extraInfoFields + "}"

        return """
        //! ARO Plugin — \(name) (ARO-0073 ABI)
        //!
        //! Implements the ARO native plugin C ABI:
        //!   aro_plugin_info      — required: return JSON metadata
        //!   aro_plugin_init      — lifecycle: called after load
        //!   aro_plugin_shutdown  — lifecycle: called before unload
        //!   aro_plugin_execute   — optional: dispatch actions
        //!   aro_plugin_free      — required: free plugin-allocated strings

        use std::ffi::{CStr, CString};
        use std::os::raw::c_char;

        // ── C ABI ──────────────────────────────────────────────────────────────

        /// Return plugin metadata as a JSON string.
        #[no_mangle]
        pub extern "C" fn aro_plugin_info() -> *mut c_char {
            let info = "\(infoJsonLiteral.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))";
            CString::new(info).unwrap().into_raw()
        }

        /// Called once after the plugin dylib is loaded.
        #[no_mangle]
        pub extern "C" fn aro_plugin_init() {
            // Allocate long-lived resources here.
        }

        /// Called once before the plugin dylib is unloaded.
        #[no_mangle]
        pub extern "C" fn aro_plugin_shutdown() {
            // Release resources here.
        }

        /// Execute a plugin action.
        ///
        /// `action`     — action name (e.g. "example")
        /// `input_json` — ARO-0073 JSON envelope:
        ///   { "result": {...}, "source": {...}, "preposition": "...",
        ///     "data": <primary value>, "_with": {...}, "_context": {...} }
        #[no_mangle]
        pub extern "C" fn aro_plugin_execute(
            action:     *const c_char,
            input_json: *const c_char,
        ) -> *mut c_char {
            let action = unsafe {
                if action.is_null() { return error_json("null action ptr") }
                CStr::from_ptr(action).to_string_lossy().into_owned()
            };
            let _input = unsafe {
                if input_json.is_null() { return error_json("null input ptr") }
                CStr::from_ptr(input_json).to_string_lossy().into_owned()
            };

            let result = match action.as_str() {
        \(matchArms)
                // TODO: Add further action handlers
                other => format!(r#"{{"error":"Unknown action: {}"}}"#, other),
            };

            CString::new(result).unwrap().into_raw()
        }

        /// Free a string allocated by this plugin.
        #[no_mangle]
        pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
            if ptr.is_null() { return }
            unsafe { drop(CString::from_raw(ptr)) }
        }

        // ── Helpers ────────────────────────────────────────────────────────────

        fn error_json(msg: &str) -> *mut c_char {
            CString::new(format!(r#"{{"error":"{}"}}"#, msg))
                .unwrap()
                .into_raw()
        }
        """
    }

    // MARK: - C Scaffold

    private func scaffoldC(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: cPluginYaml(options: options, language: .c), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let makeURL = pluginDir.appendingPathComponent("Makefile")
        try write(content: cMakefile(options: options, cpp: false), to: makeURL)
        created.append(relativePath(makeURL, to: pluginDir))

        let srcURL = pluginDir.appendingPathComponent("src/plugin.c")
        try write(content: cPluginSource(options: options, cpp: false), to: srcURL)
        created.append(relativePath(srcURL, to: pluginDir))

        // Download the C SDK header from the repo
        let includeDir = pluginDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        let sdkHeaderURL = "https://raw.githubusercontent.com/arolang/aro-plugin-sdk-c/main/include/aro_plugin_sdk.h"
        if let url = URL(string: sdkHeaderURL),
           let data = try? Data(contentsOf: url) {
            let headerPath = includeDir.appendingPathComponent("aro_plugin_sdk.h")
            try data.write(to: headerPath)
            created.append(relativePath(headerPath, to: pluginDir))
        }

        if options.includeHybrid {
            let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
            try write(content: aroFeaturesExample(options: options), to: featuresURL)
            created.append(relativePath(featuresURL, to: pluginDir))
        }

        return created
    }

    private func cPluginYaml(options: ScaffoldOptions, language: PluginLanguage) -> String {
        let name   = options.pluginName
        let handle = options.handle
        let libName = name.replacingOccurrences(of: "-", with: "_")
        let pluginType = "c-plugin"
        var provides = """
        - type: \(pluginType)
          path: src/
          handler: \(handle.lowercased())
          build:
            compiler: \(language == .cpp ? "clang++" : "clang")
            flags: [-O2, -fPIC, -shared]
            output: lib\(libName)_plugin.dylib
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A \(language == .cpp ? "C++" : "C") plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func cMakefile(options: ScaffoldOptions, cpp: Bool) -> String {
        let name    = options.pluginName
        let libName = name.replacingOccurrences(of: "-", with: "_")
        let compiler = cpp ? "CXX = clang++" : "CC = clang"
        let compilerVar = cpp ? "$(CXX)" : "$(CC)"
        let extraFlags = cpp ? " -lstdc++" : ""
        let srcExt = cpp ? "cpp" : "c"
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

    private func cPluginSource(options: ScaffoldOptions, cpp: Bool) -> String {
        let name   = options.pluginName
        let handle = options.handle

        let langComment = cpp ? "C++ plugin" : "C plugin"
        let externC     = cpp ? "extern \"C\" {\n\n" : ""
        let externCEnd  = cpp ? "\n} // extern \"C\"\n" : ""
        let include     = cpp ? "#include <cstdio>\n#include <cstdlib>\n#include <cstring>" : "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>"

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

    // MARK: - C++ Scaffold

    private func scaffoldCpp(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: cppPluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let makeURL = pluginDir.appendingPathComponent("Makefile")
        try write(content: cMakefile(options: options, cpp: true), to: makeURL)
        created.append(relativePath(makeURL, to: pluginDir))

        let srcURL = pluginDir.appendingPathComponent("src/plugin.cpp")
        try write(content: cPluginSource(options: options, cpp: true), to: srcURL)
        created.append(relativePath(srcURL, to: pluginDir))

        // Download the C/C++ SDK headers from the repo
        let includeDir = pluginDir.appendingPathComponent("include")
        try FileManager.default.createDirectory(at: includeDir, withIntermediateDirectories: true)
        for header in ["aro_plugin_sdk.h", "aro_plugin_sdk.hpp"] {
            let sdkURL = "https://raw.githubusercontent.com/arolang/aro-plugin-sdk-c/main/include/\(header)"
            if let url = URL(string: sdkURL),
               let data = try? Data(contentsOf: url) {
                let headerPath = includeDir.appendingPathComponent(header)
                try data.write(to: headerPath)
                created.append(relativePath(headerPath, to: pluginDir))
            }
        }

        if options.includeHybrid {
            let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
            try write(content: aroFeaturesExample(options: options), to: featuresURL)
            created.append(relativePath(featuresURL, to: pluginDir))
        }

        return created
    }

    private func cppPluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        let libName = name.replacingOccurrences(of: "-", with: "_")
        var provides = """
        - type: c-plugin
          path: src/
          handler: \(handle.lowercased())
          build:
            compiler: clang++
            flags: [-O2, -fPIC, -shared, -lstdc++]
            output: lib\(libName)_plugin.dylib
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A C++ plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    // MARK: - Python Scaffold

    private func scaffoldPython(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pythonPluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let srcURL = pluginDir.appendingPathComponent("src/plugin.py")
        try write(content: pythonPluginSource(options: options), to: srcURL)
        created.append(relativePath(srcURL, to: pluginDir))

        let reqURL = pluginDir.appendingPathComponent("src/requirements.txt")
        try write(content: "aro-plugin-sdk @ git+https://github.com/arolang/aro-plugin-sdk-python.git@main\n", to: reqURL)
        created.append(relativePath(reqURL, to: pluginDir))

        if options.includeHybrid {
            let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
            try write(content: aroFeaturesExample(options: options), to: featuresURL)
            created.append(relativePath(featuresURL, to: pluginDir))
        }

        return created
    }

    private func pythonPluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        var provides = """
        - type: python-plugin
          path: src/
          handler: \(handle.lowercased())
          python:
            min-version: '3.9'
            requirements: requirements.txt
        """
        if options.includeHybrid {
            provides += "\n- type: aro-files\n  path: features/"
        }
        return """
        name: \(name)
        version: 1.0.0
        handle: \(handle)
        description: A Python plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func pythonPluginSource(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle

        var actionsBlock = ""
        if options.includeActions {
            actionsBlock = """
                    {
                        "name": "example",
                        "verbs": ["example"],
                        "role": "own",
                        "prepositions": ["with", "from"],
                        "description": "An example action.",
                    },
            """
        }

        var qualifiersBlock = ""
        if options.includeQualifiers {
            qualifiersBlock = """
                    {
                        "name": "example",
                        "description": "An example qualifier.",
                        "input": "Any",
                        "output": "Any",
                    },
            """
        }

        var dispatchBlock = ""
        if options.includeActions {
            dispatchBlock = """
                if action == "example":
                    # TODO: Implement example action
                    return {"result": "ok", "action": action}
            """
        }

        return """
        \"\"\"
        ARO Plugin — \(name) (Python, ARO-0073 ABI)

        Implements the ARO Python plugin interface:
          aro_plugin_info()        — required: return metadata dict
          on_init()                — lifecycle: called once after load
          on_shutdown()            — lifecycle: called once before unload
          aro_action_<name>()      — one function per action
        \"\"\"

        from typing import Any, Dict


        def aro_plugin_info() -> Dict[str, Any]:
            \"\"\"Return plugin metadata.\"\"\"
            info: Dict[str, Any] = {
                "name": "\(name)",
                "version": "1.0.0",
                "handle": "\(handle)",
                "abi": "ARO-0073",
            }
            actions = [
        \(actionsBlock)
            ]
            qualifiers = [
        \(qualifiersBlock)
            ]
            if actions:
                info["actions"] = actions
            if qualifiers:
                info["qualifiers"] = qualifiers
            return info


        def on_init() -> None:
            \"\"\"Called once after the plugin is loaded. Allocate resources here.\"\"\"
            pass


        def on_shutdown() -> None:
            \"\"\"Called once before the plugin is unloaded. Release resources here.\"\"\"
            pass


        def aro_plugin_execute(action: str, input_json: Dict[str, Any]) -> Dict[str, Any]:
            \"\"\"
            Dispatch an action.

            input_json conforms to ARO-0073:
              {
                "result": {...}, "source": {...}, "preposition": "...",
                "data": <primary value>, "_with": {...}, "_context": {...}
              }
            \"\"\"
            with_args = input_json.get("_with", {})
            data = input_json.get("data")

        \(dispatchBlock)
            return {"error": f"Unknown action: {action}"}


        # ── Per-action helpers (optional convenience pattern) ─────────────────

        def aro_action_example(input_json: Dict[str, Any]) -> Dict[str, Any]:
            \"\"\"Example action implementation.\"\"\"
            # TODO: Implement
            return {"result": "ok"}
        """
    }

    // MARK: - ARO (pure) Scaffold

    private func scaffoldARO(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: aroPluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
        try write(content: aroFeaturesExample(options: options), to: featuresURL)
        created.append(relativePath(featuresURL, to: pluginDir))

        if options.includeTemplates {
            let templateURL = pluginDir.appendingPathComponent("templates/example.mustache")
            try write(content: aroTemplateExample(options: options), to: templateURL)
            created.append(relativePath(templateURL, to: pluginDir))
        }

        return created
    }

    private func aroPluginYaml(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        var provides = "- type: aro-files\n  path: features/"
        if options.includeTemplates {
            provides += "\n- type: aro-templates\n  path: templates/"
        }
        return """
        name: \(name)
        version: 1.0.0
        description: A pure ARO plugin that provides \(name) functionality
        author: ""
        license: MIT
        aro-version: '>=0.1.0'
        provides:
        \(provides)
        """
    }

    private func aroFeaturesExample(options: ScaffoldOptions) -> String {
        let name   = options.pluginName
        let handle = options.handle
        var featureSets = ""

        if options.includeActions || options.language == .aro {
            featureSets += """
            (* Example feature set provided by \(name) *)
            (Example Action: \(handle) Handler) {
                Log "Example action from \(name)" to the <console>.
                Return an <OK: status> for the <example>.
            }

            """
        }

        if options.includeEvents {
            featureSets += """
            (* Event handler — fires when a \(handle)Event is emitted *)
            (Handle \(handle) Event: \(handle)Event Handler) {
                Extract the <data> from the <event: data>.
                Log <data> to the <console>.
                Return an <OK: status> for the <handler>.
            }

            """
        }

        return """
        (* =============================================================================
           example.aro
           Feature sets provided by \(name)
           ============================================================================= *)

        \(featureSets.isEmpty ? "(* TODO: Add your feature sets here *)\n" : featureSets)
        """
    }

    private func aroTemplateExample(options: ScaffoldOptions) -> String {
        let name = options.pluginName
        return """
        {{! example.mustache — Template provided by \(name) }}
        <!DOCTYPE html>
        <html>
        <head><title>{{title}}</title></head>
        <body>
          <h1>{{title}}</h1>
          {{#items}}
          <p>{{.}}</p>
          {{/items}}
        </body>
        </html>
        """
    }

    // MARK: - Next Steps

    private func printNextSteps(options: ScaffoldOptions, pluginDir: URL) {
        let name   = options.pluginName
        let handle = options.handle

        print("Next steps:")
        print("")

        switch options.language {
        case .swift:
            print("  1. Edit Plugins/\(name)/Sources/\(handle)Plugin.swift")
            print("     — implement your actions in aroPluginExecute()")
            print("")
            print("  2. Build the plugin dynamic library:")
            print("     cd Plugins/\(name) && swift build -c release")
            print("")
            print("  3. Reference the plugin in your .aro application and run:")
            print("     aro run .")

        case .rust:
            print("  1. Edit Plugins/\(name)/src/lib.rs")
            print("     — implement your actions in aro_plugin_execute()")
            print("")
            print("  2. Build the plugin dynamic library:")
            print("     cd Plugins/\(name) && cargo build --release")
            print("")
            print("  3. Reference the plugin in your .aro application and run:")
            print("     aro run .")

        case .c, .cpp:
            let ext = options.language == .cpp ? "cpp" : "c"
            print("  1. Edit Plugins/\(name)/src/plugin.\(ext)")
            print("     — implement your actions in aro_plugin_execute()")
            print("")
            print("  2. Build the plugin dynamic library:")
            print("     cd Plugins/\(name) && make")
            print("")
            print("  3. Reference the plugin in your .aro application and run:")
            print("     aro run .")

        case .python:
            print("  1. Edit Plugins/\(name)/src/plugin.py")
            print("     — implement your actions in aro_plugin_execute()")
            print("")
            print("  2. Install Python dependencies (if any):")
            print("     pip install -r Plugins/\(name)/src/requirements.txt")
            print("")
            print("  3. Reference the plugin in your .aro application and run:")
            print("     aro run .")

        case .aro:
            print("  1. Edit Plugins/\(name)/features/example.aro")
            print("     — add your feature sets and event handlers")
            if options.includeTemplates {
                print("")
                print("  2. Edit Plugins/\(name)/templates/example.mustache")
                print("     — customise your Mustache templates")
            }
            print("")
            print("  \(options.includeTemplates ? "3" : "2"). Run your application:")
            print("     aro run .")
        }

        print("")
        print("Plugin handle: \(handle)")
        print("Actions are invoked as: \(handle).Verb <result> from <source>.")
        if options.includeQualifiers {
            print("Qualifiers are accessed as: <value: \(handle).qualifier-name>")
        }
    }
}

// MARK: - ScaffoldOptions

/// Captures all resolved scaffolding options, passed between helper functions.
private struct ScaffoldOptions {
    let pluginName:          String
    let handle:              String
    let language:            PluginLanguage
    let includeActions:      Bool
    let includeQualifiers:   Bool
    let includeServices:     Bool
    let includeSystemObjects: Bool
    let includeEvents:       Bool
    let includeTemplates:    Bool
    let includeHybrid:       Bool
}
