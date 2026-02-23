// ============================================================
// TerminalActions.swift
// ARO Runtime - Terminal Action Implementations (ARO-0052)
// ============================================================

import Foundation
import AROParser

// MARK: - Prompt Action

/// Prompts the user for text input via terminal
///
/// The Prompt action requests text input from the user through the terminal.
/// Supports hidden input for password entry.
///
/// ## Examples
/// ```
/// Prompt the <name> with "Enter your name: " from the <terminal>.
/// Prompt the <password: hidden> with "Password: " from the <terminal>.
/// ```
public struct PromptAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["prompt", "ask"]
    public static let validPrepositions: Set<Preposition> = [.with, .from]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get message from _with_ binding (e.g., with "Enter name:")
        guard let message = context.resolveAny("_with_") as? String else {
            let received = context.resolveAny("_with_").map { String(describing: $0) } ?? "nil"
            throw ActionError.invalidInput("Prompt action requires a message string via 'with' clause", received: received)
        }

        // Check for hidden specifier (password mode)
        let hidden = result.specifiers.contains { $0.lowercased() == "hidden" }

        // Get terminal service from context
        guard let terminalService = context.service(TerminalService.self) else {
            throw ActionError.runtimeError("Terminal service not available")
        }

        // Prompt for input
        let input = await terminalService.prompt(message: message, hidden: hidden)

        // Bind result to context
        context.bind(result.base, value: input)

        // Return result
        return PromptResult(value: input, hidden: hidden)
    }
}

// MARK: - Select Action

/// Displays an interactive selection menu
///
/// The Select action presents a list of options and allows the user to choose one or more.
///
/// ## Examples
/// ```
/// Select the <choice> from <options> with "Choose:" from the <terminal>.
/// Select the <choices: multi-select> from <options> with "Select items:" from the <terminal>.
/// ```
public struct SelectAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["select", "choose"]
    public static let validPrepositions: Set<Preposition> = [.from, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get message from _with_ binding
        guard let message = context.resolveAny("_with_") as? String else {
            let received = context.resolveAny("_with_").map { String(describing: $0) } ?? "nil"
            throw ActionError.invalidInput("Select action requires a message string via 'with' clause", received: received)
        }

        // Get options array from object
        guard let optionsValue = context.resolveAny(object.base) else {
            throw ActionError.invalidInput("Select action requires an options array from '\(object.base)'", received: "nil")
        }

        // Convert to string array
        let options: [String]
        if let stringArray = optionsValue as? [String] {
            options = stringArray
        } else if let sendableArray = optionsValue as? [any Sendable] {
            options = sendableArray.map { String(describing: $0) }
        } else if let anyArray = optionsValue as? [Any] {
            options = anyArray.map { String(describing: $0) }
        } else {
            let received = String(describing: optionsValue)
            throw ActionError.invalidInput("Select action requires an array of options", received: received)
        }

        // Check for multi-select specifier
        let multiSelect = result.specifiers.contains { $0.lowercased().contains("multi") }

        // Get terminal service from context
        guard let terminalService = context.service(TerminalService.self) else {
            throw ActionError.runtimeError("Terminal service not available")
        }

        // Display selection menu
        let selected = await terminalService.select(
            options: options,
            message: message,
            multiSelect: multiSelect
        )

        // Bind result to context
        if multiSelect {
            context.bind(result.base, value: selected)
        } else {
            // Single selection - bind the first (and only) selected item
            let selectedItem = selected.first ?? ""
            context.bind(result.base, value: selectedItem)
        }

        // Return result
        return SelectResult(selected: selected, multiSelect: multiSelect)
    }
}

// MARK: - Clear Action

/// Clears the terminal screen or line
///
/// The Clear action erases content from the terminal display.
///
/// ## Examples
/// ```
/// Clear the <screen> for the <terminal>.
/// Clear the <line> for the <terminal>.
/// ```
public struct ClearAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["clear"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Get terminal service from context
        guard let terminalService = context.service(TerminalService.self) else {
            throw ActionError.runtimeError("Terminal service not available")
        }

        // Determine what to clear based on result base
        let target = result.base.lowercased()

        switch target {
        case "screen":
            await terminalService.clear()
        case "line":
            await terminalService.clearLine()
        default:
            throw ActionError.invalidInput("Clear action supports 'screen' or 'line'", received: result.base)
        }

        // Bind result to context
        context.bind(result.base, value: target)

        // Return result
        return ClearResult(targetCleared: target)
    }
}
