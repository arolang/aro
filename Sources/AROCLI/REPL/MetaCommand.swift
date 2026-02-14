// MetaCommand.swift
// ARO REPL Meta-Command Protocol and Registry
//
// Protocol for REPL commands that start with ':'

import Foundation

/// Result of executing a meta-command
public enum MetaCommandResult: Sendable {
    case output(String)
    case table([[String]])
    case clear
    case exit
    case none
    case error(String)
}

/// Protocol for REPL meta-commands
public protocol MetaCommand: Sendable {
    /// The command name (without colon prefix)
    static var name: String { get }

    /// Aliases for the command
    static var aliases: [String] { get }

    /// Help text
    static var help: String { get }

    /// Required initializer
    init()

    /// Execute the command
    func execute(args: [String], session: REPLSession) async throws -> MetaCommandResult
}

/// A command factory that creates instances
private struct CommandFactory: Sendable {
    let name: String
    let create: @Sendable () -> any MetaCommand

    init<C: MetaCommand>(_ type: C.Type) {
        self.name = C.name
        self.create = { C() }
    }
}

/// Registry for meta-commands
public final class MetaCommandRegistry: Sendable {
    public static let shared = MetaCommandRegistry()

    private let commands: [String: CommandFactory]

    private init() {
        var cmds: [String: CommandFactory] = [:]

        // Register each command with its name and aliases
        func register<C: MetaCommand>(_ type: C.Type) {
            let factory = CommandFactory(type)
            cmds[C.name.lowercased()] = factory
            for alias in C.aliases {
                cmds[alias.lowercased()] = factory
            }
        }

        register(HelpCommand.self)
        register(VarsCommand.self)
        register(TypeCommand.self)
        register(ClearCommand.self)
        register(HistoryCommand.self)
        register(FSCommand.self)
        register(InvokeCommand.self)
        register(SetCommand.self)
        register(ExportCommand.self)
        register(LoadCommand.self)
        register(QuitCommand.self)

        self.commands = cmds
    }

    public func execute(
        input: String,
        session: REPLSession
    ) async throws -> MetaCommandResult {
        // Parse command and arguments
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(":") else {
            return .error("Not a meta-command")
        }

        let withoutColon = String(trimmed.dropFirst())
        let parts = parseCommandLine(withoutColon)

        guard let commandName = parts.first else {
            return .error("Empty command")
        }

        let args = Array(parts.dropFirst())

        guard let factory = commands[commandName.lowercased()] else {
            return .error("Unknown command ':\(commandName)'. Type :help for available commands.")
        }

        let command = factory.create()
        return try await command.execute(args: args, session: session)
    }

    /// Get all registered command names (for completion)
    public var commandNames: [String] {
        var names = Set<String>()
        for (_, factory) in commands {
            names.insert(factory.name)
        }
        return names.sorted()
    }

    /// Parse command line respecting quotes
    private func parseCommandLine(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for char in input {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }

            if char == "\\" {
                escaped = true
                continue
            }

            if char == "\"" {
                inQuotes.toggle()
                continue
            }

            if char == " " && !inQuotes {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }

            current.append(char)
        }

        if !current.isEmpty {
            parts.append(current)
        }

        return parts
    }
}
