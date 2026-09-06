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
            "     — add .action / .qualifier entries to the AROPlugin builder",
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
        // AROPluginKit provides the @AROExport macro and the AROPlugin builder.

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
                        .product(name: "AROPluginKit", package: "aro-plugin-sdk-swift"),
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

        var builderChain = ""
        if options.includeActions {
            builderChain += """

                .action("Example", verbs: ["example"], role: "own", prepositions: ["with", "from"],
                        description: "An example action provided by \(name).") { input in
                    // Invoked from ARO as: \(handle).Example the <result> from <source>.
                    let data = input.string("data") ?? ""
                    // TODO: Implement your action logic
                    return .success(["result": "ok", "data": data])
                }
            """
        }
        if options.includeQualifiers {
            builderChain += """

                .qualifier("example", inputTypes: ["String"],
                           description: "Uppercases a string (example qualifier).") { params in
                    // Accessed from ARO as: <value: \(handle).example>
                    guard let string = params.stringValue else {
                        return .failure("example requires a string")
                    }
                    return .success(string.uppercased())
                }
            """
        }
        if options.includeServices {
            builderChain += """

                .service("\(handle)Service", methods: ["status"],
                         description: "An example service provided by \(name).") { method, _ in
                    // TODO: Implement your service methods
                    return .success(["method": method, "status": "ok"])
                }
            """
        }

        return """
        // ============================================================
        // \(handle)Plugin.swift
        // ARO Plugin - \(name)
        // ============================================================
        //
        // Uses the ARO Plugin SDK (AROPluginKit) zero-boilerplate pattern.
        // No @_cdecl, no JSON, no manual memory management: the @AROExport
        // macro generates all C ABI exports the ARO runtime needs
        // (aro_plugin_info, aro_plugin_execute, aro_plugin_qualifier,
        // aro_plugin_free, aro_plugin_init, aro_plugin_shutdown).

        import Foundation
        import AROPluginKit

        /// Plugin registration — this is the ONLY setup needed.
        @AROExport
        private let plugin = AROPlugin(name: "\(name)", version: "1.0.0", handle: "\(handle)")\(builderChain)
        """
    }
}
