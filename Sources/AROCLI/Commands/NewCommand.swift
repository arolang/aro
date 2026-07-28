// ============================================================
// NewCommand.swift
// ARO CLI - Scaffold New Plugin Command
// ============================================================
//
// Argument parsing and dispatch only. Each language's templates and file
// generation live in Scaffold/<Language>PluginScaffold.swift behind the
// `PluginScaffold` protocol (ARO-364); adding a language means adding one file.

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
struct NewPluginCommand: AsyncParsableCommand {
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

    func run() async throws {
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
            includeQualifiers:   qualifiers,
            includeServices:     services,
            includeSystemObjects: systemObjects,
            includeEvents:       events,
            includeTemplates:    templates,
            includeHybrid:       hybrid
        )

        print("Scaffolding \(lang.displayName) plugin \"\(pluginName)\" (handle: \(resolvedHandle))...")
        print("")

        do {
            // Run the scaffold (directory creation, file writes, SDK header
            // downloads) on a background task so the terminal stays responsive.
            let files = try await FileOps.background {
                try Self.generateScaffold(options: options, pluginDir: pluginDir)
            }

            for file in files {
                print("  + \(file)")
            }

            print("")
            print("Plugin created at Plugins/\(pluginName)/")
            print("")
            printNextSteps(options: options)

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

    /// Create the plugin directory and delegate file generation to the
    /// language's `PluginScaffold`.
    private static func generateScaffold(options: ScaffoldOptions, pluginDir: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        let scaffold = PluginScaffoldFactory.scaffold(for: options.language)
        return try scaffold.generate(options: options, pluginDir: pluginDir)
    }

    // MARK: - Next Steps

    private func printNextSteps(options: ScaffoldOptions) {
        let handle = options.handle
        print("Next steps:")
        print("")

        let scaffold = PluginScaffoldFactory.scaffold(for: options.language)
        for line in scaffold.nextSteps(options: options) {
            print(line)
        }

        print("")
        print("Plugin handle: \(handle)")
        print("Actions are invoked as: \(handle).Verb <result> from <source>.")
        if options.includeQualifiers {
            print("Qualifiers are accessed as: <value: \(handle).qualifier-name>")
        }
    }
}
