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
              aro actions                         # List all built-in and plugin actions
              aro actions Log                     # Show one action, by name or by any of its verbs
              aro actions createdirectory         # Aliases resolve too
              aro actions --qualifiers            # Also list registered qualifiers
              aro actions --format json           # Machine-readable output
              aro actions -d ./MyApp              # Load plugins from MyApp and list all actions
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

    @Option(name: .long, help: "Output format: text (default) or json")
    var format: String = "text"

    @Argument(help: "Action name or verb to look up. Omit to list everything.")
    var name: String?

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
                FileHandle.standardError.write(Data("Warning: Failed to load plugins: \(error)\n".utf8))
            }
        }

        let builtIns = ActionRegistry.shared.allBuiltInActionInfos
        let pluginActions = ActionRegistry.shared.allPluginActionInfos
        let asJSON = format.lowercased() == "json"

        // -- Single-action lookup --
        if let query = name {
            try lookUp(query, builtIns: builtIns, pluginActions: pluginActions, asJSON: asJSON)
            return
        }

        if asJSON {
            printJSON(
                builtIns: builtIns,
                pluginActions: pluginActions,
                qualifierRegistrations: qualifiers
                    ? QualifierRegistry.shared.allRegistrations() : []
            )
            return
        }

        printBuiltInActions(builtIns)

        if !pluginActions.isEmpty {
            printPluginActions(pluginActions)
        }

        if qualifiers {
            let registrations = QualifierRegistry.shared.allRegistrations()
            printQualifiers(registrations)
        }
    }

    // MARK: - Single-Action Lookup

    /// Resolves `query` against canonical names *and* verb aliases.
    ///
    /// Alias resolution is the point: `CreateDirectory` and `Keepalive` appear in
    /// the project's own examples and documentation but are verbs of `Make` and
    /// `WaitForEvents`, so looking them up used to find nothing and a user would
    /// reasonably conclude the action had been removed (GitLab #483).
    private func lookUp(
        _ query: String,
        builtIns: [ActionRegistry.BuiltInActionInfo],
        pluginActions: [ActionRegistry.PluginActionInfo],
        asJSON: Bool
    ) throws {
        let needle = query.lowercased()

        if let match = builtIns.first(where: {
            $0.name.lowercased() == needle || $0.verbs.contains { $0.lowercased() == needle }
        }) {
            if asJSON {
                printJSON(builtIns: [match], pluginActions: [])
            } else {
                printActionDetail(match, queriedAs: query)
            }
            return
        }

        if let plugin = pluginActions.first(where: { $0.verb.lowercased() == needle }) {
            if asJSON {
                printJSON(builtIns: [], pluginActions: [plugin])
            } else {
                print("")
                print("\(plugin.verb)  (plugin action)")
                print("  Plugin: \(plugin.pluginName ?? "(anonymous)")")
                print("")
            }
            return
        }

        // Suggest near matches over any name or alias, so a typo is recoverable.
        // Suggest canonical names only — offering both "Log" and its own verb
        // "log" is noise, since looking up either resolves to the same action.
        let suggestions = builtIns
            .filter { action in
                let names = [action.name] + action.verbs
                return names.contains {
                    $0.lowercased().contains(needle) || needle.contains($0.lowercased())
                }
            }
            .map(\.name)
            .sorted()
            .prefix(5)

        var message = "No action named '\(query)'."
        if !suggestions.isEmpty {
            message += " Did you mean: \(suggestions.joined(separator: ", "))?"
        } else {
            message += " Run 'aro actions' to list them all."
        }
        throw ValidationError(message)
    }

    private func printActionDetail(_ action: ActionRegistry.BuiltInActionInfo, queriedAs query: String) {
        print("")
        let aliases = action.verbs.sorted()
        print("\(action.name)")
        if action.name.lowercased() != query.lowercased() {
            print("  (matched the verb '\(query.lowercased())')")
        }
        print("  Role:         \(action.role.rawValue)")
        print("  Verbs:        \(aliases.joined(separator: ", "))")
        let preps = action.prepositions.isEmpty ? "(any)" : action.prepositions.sorted().joined(separator: ", ")
        print("  Prepositions: \(preps)")
        print("")
        print("  Example: \(exampleStatement(for: action))")
        print("")
    }

    /// A minimal well-formed statement for the action, so the shape is obvious.
    ///
    /// Uses the canonical name rather than the alphabetically-first verb, so the
    /// example reads `Make the <result> …` and not `Createdirectory the <result> …`.
    private func exampleStatement(for action: ActionRegistry.BuiltInActionInfo) -> String {
        let preposition = action.prepositions.sorted().first ?? "with"
        return "\(action.name) the <result> \(preposition) the <object>."
    }

    // MARK: - JSON Output

    /// Emits the catalog as JSON so SOLARO, the LSP and the MCP server can consume
    /// one source instead of each maintaining a partial mirror.
    private func printJSON(
        builtIns: [ActionRegistry.BuiltInActionInfo],
        pluginActions: [ActionRegistry.PluginActionInfo],
        qualifierRegistrations: [QualifierRegistration] = []
    ) {
        var payload: [String: Any] = [:]
        payload["builtin"] = builtIns.map { action in
            [
                "name": action.name,
                "role": action.role.rawValue,
                "verbs": action.verbs.sorted(),
                "prepositions": action.prepositions.sorted()
            ] as [String: Any]
        }
        payload["plugin"] = pluginActions.map { entry in
            [
                "verb": entry.verb,
                "plugin": entry.pluginName ?? ""
            ] as [String: Any]
        }
        // GitLab #486: `--qualifiers --format json` used to drop the
        // qualifier section silently — the payload only ever carried
        // actions. Anything generating a catalog from this command
        // therefore had no way to learn what qualifiers exist, which
        // is why the training pipeline never gained the gate that
        // actions already had.
        if !qualifierRegistrations.isEmpty {
            payload["qualifiers"] = qualifierRegistrations
                .sorted { lhs, rhs in
                    if lhs.namespace != rhs.namespace {
                        // Built-ins first, then plugin namespaces.
                        if lhs.namespace == "_builtin" { return true }
                        if rhs.namespace == "_builtin" { return false }
                        return lhs.namespace < rhs.namespace
                    }
                    return lhs.qualifier < rhs.qualifier
                }
                .map { reg in
                    [
                        "name": reg.qualifier,
                        "namespace": reg.namespace,
                        "qualified": "\(reg.namespace).\(reg.qualifier)",
                        "builtin": reg.namespace == "_builtin",
                        "plugin": reg.pluginName,
                        "inputTypes": reg.inputTypes.map(\.rawValue).sorted(),
                        "acceptsParameters": reg.acceptsParameters,
                        "description": reg.description ?? ""
                    ] as [String: Any]
                }
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(Data("Error: could not serialise action catalog\n".utf8))
            return
        }
        print(text)
    }

    // MARK: - Formatting

    private func printBuiltInActions(_ actions: [ActionRegistry.BuiltInActionInfo]) {
        print("")
        print("Built-in Actions:")
        print("─────────────────────────────────────────────────────")

        // Column widths
        let nameWidth  = max(16, actions.map { $0.name.count }.max() ?? 16)
        let roleWidth  = 10
        let prepWidth  = 22

        let nameHdr  = "Name".padding(toLength: nameWidth,  withPad: " ", startingAt: 0)
        let roleHdr  = "Role".padding(toLength: roleWidth,  withPad: " ", startingAt: 0)
        let prepHdr  = "Prepositions".padding(toLength: prepWidth, withPad: " ", startingAt: 0)
        print("  \(nameHdr)  \(roleHdr)  \(prepHdr)  Verbs")
        print("  \(String(repeating: "─", count: nameWidth))  \(String(repeating: "─", count: roleWidth))  \(String(repeating: "─", count: prepWidth))  \(String(repeating: "─", count: 40))")

        for action in actions {
            let name  = action.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            let role  = action.role.rawValue.padding(toLength: roleWidth, withPad: " ", startingAt: 0)
            let preps = (action.prepositions.isEmpty ? "(any)" : action.prepositions.sorted().joined(separator: ", "))
                          .padding(toLength: prepWidth, withPad: " ", startingAt: 0)
            // Verbs are the spellings users actually write. Omitting them made
            // `CreateDirectory` and `Keepalive` — both in this project's own
            // examples — impossible to find here (GitLab #483).
            let verbs = action.verbs.sorted().joined(separator: ", ")
            print("  \(name)  \(role)  \(preps)  \(verbs)")
        }

        print("")
        print("  \(actions.count) built-in \(actions.count == 1 ? "action" : "actions")")
        print("  Run 'aro actions <name-or-verb>' for one action's details.")
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
