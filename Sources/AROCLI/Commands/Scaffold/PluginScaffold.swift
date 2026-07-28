// ============================================================
// PluginScaffold.swift
// ARO CLI - Plugin scaffolding protocol + shared helpers
// ============================================================

import Foundation

// MARK: - ScaffoldOptions

/// Captures all resolved scaffolding options, passed to each `PluginScaffold`.
struct ScaffoldOptions: Sendable {
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

// MARK: - PluginScaffold

/// A per-language plugin scaffolder. Each concrete conformer owns the template
/// selection and file generation for exactly one language, so adding a new
/// target language means adding one file — not editing a monolith (ARO-364).
protocol PluginScaffold: Sendable {
    /// Write the plugin's files under `pluginDir` (which already exists) and
    /// return the created file paths, relative to the `Plugins/` parent.
    func generate(options: ScaffoldOptions, pluginDir: URL) throws -> [String]

    /// Language-specific "Next steps:" lines printed after generation. The
    /// shared trailing lines (handle, invocation syntax) are added by the caller.
    func nextSteps(options: ScaffoldOptions) -> [String]
}

// MARK: - Shared helpers

extension PluginScaffold {
    /// Write `content` to `url`, creating intermediate directories.
    func write(content: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Return `url` rendered relative to the `Plugins/` parent (e.g.
    /// `Plugins/my-csv/plugin.yaml`).
    func relativePath(_ url: URL, to base: URL) -> String {
        let pluginsDirPath = base.deletingLastPathComponent().path
        let fullPath = url.path
        if fullPath.hasPrefix(pluginsDirPath + "/") {
            return "Plugins/" + String(fullPath.dropFirst(pluginsDirPath.count + 1))
        }
        return fullPath
    }

    /// Native-language scaffolds append an aro-files provider in hybrid mode;
    /// this writes the shared `features/example.aro` and records it.
    func appendHybridFeatures(options: ScaffoldOptions, pluginDir: URL,
                              into created: inout [String]) throws {
        guard options.includeHybrid else { return }
        let featuresURL = pluginDir.appendingPathComponent("features/example.aro")
        try write(content: aroFeaturesExample(options: options), to: featuresURL)
        created.append(relativePath(featuresURL, to: pluginDir))
    }

    /// The example feature-set file shared by the ARO scaffold and hybrid mode.
    func aroFeaturesExample(options: ScaffoldOptions) -> String {
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

    /// The example Mustache template used by the ARO scaffold's `--templates`.
    func aroTemplateExample(options: ScaffoldOptions) -> String {
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
}

// MARK: - Factory

/// Resolves the `PluginScaffold` for a language. The one place that knows the
/// full language → scaffolder mapping.
enum PluginScaffoldFactory {
    static func scaffold(for language: PluginLanguage) -> PluginScaffold {
        switch language {
        case .swift:  return SwiftPluginScaffold()
        case .rust:   return RustPluginScaffold()
        case .c:      return CPluginScaffold()
        case .cpp:    return CppPluginScaffold()
        case .python: return PythonPluginScaffold()
        case .aro:    return AROPluginScaffold()
        }
    }
}
