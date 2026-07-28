// ============================================================
// SwiftPluginScaffold.swift
// ARO CLI - Swift plugin scaffolding
// ============================================================

import Foundation

/// Scaffolds a Swift plugin (plugin.yaml, Package.swift, Sources/<Handle>Plugin.swift).
struct SwiftPluginScaffold: PluginScaffold {
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []
        let handle = options.handle

        // plugin.yaml
        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pluginYaml(options: options), to: yamlURL)
        created.append(relativePath(yamlURL, to: pluginDir))

        // Package.swift
        let pkgURL = pluginDir.appendingPathComponent("Package.swift")
        try write(content: packageSwift(options: options), to: pkgURL)
        created.append(relativePath(pkgURL, to: pluginDir))

        // Sources/<Handle>Plugin.swift
        let sourcesDir = pluginDir.appendingPathComponent("Sources", isDirectory: true)
        let swiftURL   = sourcesDir.appendingPathComponent("\(handle)Plugin.swift")
        try write(content: pluginSource(options: options), to: swiftURL)
        created.append(relativePath(swiftURL, to: pluginDir))

        try appendHybridFeatures(options: options, pluginDir: pluginDir, into: &created)
        return created
    }

    func nextSteps(options: ScaffoldOptions) -> [String] {
        let name = options.pluginName
        let handle = options.handle
        return [
            "  1. Edit Plugins/\(name)/Sources/\(handle)Plugin.swift",
            "     — implement your actions in aroPluginExecute()",
            "",
            "  2. Build the plugin dynamic library:",
            "     cd Plugins/\(name) && swift build -c release",
            "",
            "  3. Reference the plugin in your .aro application and run:",
            "     aro run .",
        ]
    }

    // MARK: - Templates

    private func pluginYaml(options: ScaffoldOptions) -> String {
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
            minimum-version: '6.3'
            targets:
            - name: \(handle)Plugin
              path: Sources/
        """
    }

    private func packageSwift(options: ScaffoldOptions) -> String {
        let handle = options.handle
        return """
        // swift-tools-version: 6.3
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

    private func pluginSource(options: ScaffoldOptions) -> String {
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

        let executeBody = buildExecuteBody(options: options)

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

    private func buildExecuteBody(options: ScaffoldOptions) -> String {
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
}
