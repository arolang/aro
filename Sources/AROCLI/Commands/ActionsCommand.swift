// ============================================================
// ActionsCommand.swift
// ARO CLI - Actions Inspection Command
// ============================================================

import ArgumentParser
import Foundation
import ARORuntime

/// Command group for inspecting registered actions and qualifiers
struct ActionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions",
        abstract: "Manage and inspect actions",
        discussion: """
            Commands for inspecting ARO actions and qualifiers.

            Example:
              aro actions list                   # List all built-in and plugin actions
              aro actions list --qualifiers       # Also list registered qualifiers
              aro actions list -d ./MyApp         # Load plugins from MyApp and list all actions
            """,
        subcommands: [ListActions.self],
        defaultSubcommand: ListActions.self
    )
}

// MARK: - List Actions

/// List all registered actions and optionally qualifiers
struct ListActions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all registered actions and qualifiers"
    )

    @Option(name: .shortAndLong, help: "Application directory to load plugins from (default: current directory)")
    var directory: String?

    @Flag(name: .long, help: "Also list registered qualifiers")
    var qualifiers: Bool = false

    func run() async throws {
        let appDir = directory.map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        // Load plugins so plugin actions/qualifiers are registered
        if FileManager.default.fileExists(atPath: appDir.appendingPathComponent("Plugins").path) ||
           FileManager.default.fileExists(atPath: appDir.appendingPathComponent("plugins").path) {
            do {
                try UnifiedPluginLoader.shared.loadPlugins(from: appDir)
            } catch {
                // Non-fatal: print warning but continue showing built-ins
                fputs("Warning: Failed to load plugins: \(error)\n", stderr)
            }
        }

        // -- Built-in Actions --
        let builtIns = await ActionRegistry.shared.allBuiltInActionInfos
        printBuiltInActions(builtIns)

        // -- Plugin Actions --
        let pluginActions = await ActionRegistry.shared.allPluginActionInfos
        if !pluginActions.isEmpty {
            printPluginActions(pluginActions)
        }

        // -- Qualifiers --
        if qualifiers {
            let registrations = QualifierRegistry.shared.allRegistrations()
            printQualifiers(registrations)
        }
    }

    // MARK: - Formatting

    private func printBuiltInActions(_ actions: [ActionRegistry.BuiltInActionInfo]) {
        print("")
        print("Built-in Actions:")
        print("─────────────────────────────────────────────────────")

        // Column widths
        let nameWidth  = max(16, actions.map { $0.name.count }.max() ?? 16)
        let roleWidth  = 10
        let prepWidth  = 30

        let nameHdr  = "Name".padding(toLength: nameWidth,  withPad: " ", startingAt: 0)
        let roleHdr  = "Role".padding(toLength: roleWidth,  withPad: " ", startingAt: 0)
        let prepHdr  = "Prepositions".padding(toLength: prepWidth, withPad: " ", startingAt: 0)
        print("  \(nameHdr)  \(roleHdr)  \(prepHdr)")
        print("  \(String(repeating: "─", count: nameWidth))  \(String(repeating: "─", count: roleWidth))  \(String(repeating: "─", count: prepWidth))")

        for action in actions {
            let name  = action.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let role  = action.role.rawValue.padding(toLength: roleWidth, withPad: " ", startingAt: 0)
            let preps = action.prepositions.isEmpty ? "(any)" : action.prepositions.joined(separator: ", ")
            print("  \(name)  \(role)  \(preps)")
        }

        print("")
        print("  \(actions.count) built-in \(actions.count == 1 ? "action" : "actions")")
    }

    private func printPluginActions(_ actions: [ActionRegistry.PluginActionInfo]) {
        // Group by plugin name for cleaner output
        var byPlugin: [String: [String]] = [:]
        for entry in actions {
            let key = entry.pluginName ?? "(anonymous)"
            byPlugin[key, default: []].append(entry.verb)
        }

        print("")
        print("Plugin Actions:")
        print("─────────────────────────────────────────────────────")

        let verbWidth   = max(20, actions.map { $0.verb.count }.max() ?? 20)
        let pluginWidth = max(24, byPlugin.keys.map { $0.count }.max() ?? 24)

        let verbHdr   = "Verb".padding(toLength: verbWidth,   withPad: " ", startingAt: 0)
        let pluginHdr = "Plugin".padding(toLength: pluginWidth, withPad: " ", startingAt: 0)
        print("  \(verbHdr)  \(pluginHdr)")
        print("  \(String(repeating: "─", count: verbWidth))  \(String(repeating: "─", count: pluginWidth))")

        for entry in actions {
            let verb   = entry.verb.padding(toLength: verbWidth, withPad: " ", startingAt: 0)
            let plugin = (entry.pluginName ?? "(anonymous)").padding(toLength: pluginWidth, withPad: " ", startingAt: 0)
            print("  \(verb)  \(plugin)")
        }

        print("")
        print("  \(actions.count) plugin \(actions.count == 1 ? "action" : "actions")")
    }

    private func printQualifiers(_ registrations: [QualifierRegistration]) {
        let sorted = registrations.sorted { lhs, rhs in
            // Built-ins first, then by namespace+qualifier
            if lhs.pluginName == "_builtin" && rhs.pluginName != "_builtin" { return true }
            if lhs.pluginName != "_builtin" && rhs.pluginName == "_builtin" { return false }
            let lKey = "\(lhs.namespace).\(lhs.qualifier)"
            let rKey = "\(rhs.namespace).\(rhs.qualifier)"
            return lKey < rKey
        }

        print("")
        print("Qualifiers:")
        print("─────────────────────────────────────────────────────")

        let keyWidth    = max(24, sorted.map { "\($0.namespace).\($0.qualifier)".count }.max() ?? 24)
        let typesWidth  = 28
        let sourceWidth = max(12, sorted.map { ($0.pluginName == "_builtin" ? "Built-in" : $0.pluginName).count }.max() ?? 12)

        let keyHdr    = "Qualifier".padding(toLength: keyWidth,    withPad: " ", startingAt: 0)
        let typesHdr  = "Input Types".padding(toLength: typesWidth, withPad: " ", startingAt: 0)
        let sourceHdr = "Source".padding(toLength: sourceWidth,  withPad: " ", startingAt: 0)
        print("  \(keyHdr)  \(typesHdr)  \(sourceHdr)")
        print("  \(String(repeating: "─", count: keyWidth))  \(String(repeating: "─", count: typesWidth))  \(String(repeating: "─", count: sourceWidth))")

        for reg in sorted {
            let key    = "\(reg.namespace).\(reg.qualifier)".padding(toLength: keyWidth, withPad: " ", startingAt: 0)
            let types  = reg.inputTypes.map { $0.rawValue }.sorted().joined(separator: ", ")
                           .padding(toLength: typesWidth, withPad: " ", startingAt: 0)
            let source = (reg.pluginName == "_builtin" ? "Built-in" : reg.pluginName)
                           .padding(toLength: sourceWidth, withPad: " ", startingAt: 0)
            print("  \(key)  \(types)  \(source)")
        }

        print("")
        print("  \(sorted.count) \(sorted.count == 1 ? "qualifier" : "qualifiers")")
    }
}
