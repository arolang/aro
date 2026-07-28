// ============================================================
// AROPluginScaffold.swift
// ARO CLI - Pure-ARO plugin scaffolding
// ============================================================

import Foundation

/// Scaffolds a pure-ARO plugin (plugin.yaml, features/example.aro, optional
/// templates/example.mustache). The `aroFeaturesExample` / `aroTemplateExample`
/// templates live in the shared `PluginScaffold` extension (they're reused by
/// hybrid mode).
struct AROPluginScaffold: PluginScaffold {
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        var created: [String] = []

        let yamlURL = pluginDir.appendingPathComponent("plugin.yaml")
        try write(content: pluginYaml(options: options), to: yamlURL)
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

    func nextSteps(options: ScaffoldOptions) -> [String] {
        let name = options.pluginName
        var lines = [
            "  1. Edit Plugins/\(name)/features/example.aro",
            "     — add your feature sets and event handlers",
        ]
        if options.includeTemplates {
            lines += [
                "",
                "  2. Edit Plugins/\(name)/templates/example.mustache",
                "     — customise your Mustache templates",
            ]
        }
        lines += [
            "",
            "  \(options.includeTemplates ? "3" : "2"). Run your application:",
            "     aro run .",
        ]
        return lines
    }

    // MARK: - Templates

    private func pluginYaml(options: ScaffoldOptions) -> String {
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
}
