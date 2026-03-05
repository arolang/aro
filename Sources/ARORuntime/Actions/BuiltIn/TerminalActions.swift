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

        let target = result.base.lowercased()

        // Get terminal service from context (only available in TTY mode)
        if let terminalService = context.service(TerminalService.self) {
            switch target {
            case "screen":
                await terminalService.clear()
            case "line":
                await terminalService.clearLine()
            case "cursor":
                await terminalService.hideCursor()
            default:
                throw ActionError.invalidInput("Clear action supports 'screen', 'line', or 'cursor'", received: result.base)
            }
        }
        // Non-TTY: no-op (can't clear a pipe/redirect)

        // Bind result to context (allowRebind: cursor can be hidden then shown in same feature set)
        context.bind(result.base, value: target, allowRebind: true)

        // Return result
        return ClearResult(targetCleared: target)
    }
}

// MARK: - Show Action

/// Shows a terminal element (e.g. the cursor)
///
/// ## Examples
/// ```
/// Show the <cursor> for the <terminal>.
/// ```
public struct ShowAction: ActionImplementation {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["show"]
    public static let validPrepositions: Set<Preposition> = [.for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        let target = result.base.lowercased()

        if let terminalService = context.service(TerminalService.self) {
            switch target {
            case "cursor":
                await terminalService.showCursor()
            default:
                throw ActionError.invalidInput("Show action supports 'cursor'", received: result.base)
            }
        }
        // Non-TTY: no-op

        context.bind(result.base, value: target, allowRebind: true)
        return target
    }
}

// MARK: - Render Action

/// Reactively renders content to the terminal for interactive UIs
///
/// The Render action is designed for interactive terminal applications.
/// In TTY mode: clears the screen and renders fresh content (reactive update).
/// In non-TTY mode (pipes, tests): outputs content like Log.
///
/// ## Examples
/// ```aro
/// Render the <menu> to the <console>.
/// Render the <task-list> to the <console>.
/// ```
public struct RenderAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["render"]
    public static let validPrepositions: Set<Preposition> = [.to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // Get the content to render
        let content: String
        if let value = context.resolveAny(result.base) as? String {
            content = value
        } else if let value = context.resolveAny(result.base) {
            content = String(describing: value)
        } else {
            content = ""
        }

        // Section-based compositor: each named render owns its rows on screen.
        // Static sections stay put; reactive sections update only their own rows.
        if let terminalService = context.service(TerminalService.self) {
            // Pass any tracked template-variable positions for reactive Repaint updates
            let positionsKey = "_positions_\(result.base)_"
            let positions = context.resolveAny(positionsKey) as? [String: TerminalVarPosition] ?? [:]
            await terminalService.renderSection(name: result.base, content: content, variablePositions: positions)
        } else {
            // Non-TTY fallback (tests, pipes): output like Log
            print(content)
        }

        return RenderResult(content: content)
    }
}

// MARK: - Repaint Action

/// Reactively updates a single variable's value in a rendered section without re-rendering the template.
///
/// Uses the position tracked by the last Transform+Render call to write the new value
/// directly to the terminal at the correct row and column.
///
/// ## Example
/// ```aro
/// Compute the <cpu-bar: progress-bar> from the <cpu>.
/// Repaint the <cpu>     at the <display>.
/// Repaint the <cpu-bar> at the <display>.
/// ```
public struct RepaintAction: ActionImplementation {
    public static let role: ActionRole = .response
    public static let verbs: Set<String> = ["repaint", "patch"]
    public static let validPrepositions: Set<Preposition> = [.at, .to]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        guard let terminalService = context.service(TerminalService.self) else {
            // Non-TTY: no-op (no section compositor available)
            return RepaintResult(variable: result.base, sectionName: object.base)
        }

        // Get the new value to write
        guard let rawValue = context.resolveAny(result.base) else {
            return RepaintResult(variable: result.base, sectionName: object.base)
        }

        // Format the value as a displayable string
        let formatted: String
        if let s = rawValue as? String { formatted = s }
        else if let i = rawValue as? Int { formatted = String(i) }
        else if let d = rawValue as? Double { formatted = String(d) }
        else { formatted = String(describing: rawValue) }

        // Write directly to the tracked position in the section
        await terminalService.updateVariable(name: result.base, value: formatted, inSection: object.base)

        return RepaintResult(variable: result.base, sectionName: object.base)
    }
}

/// Result of a repaint operation
public struct RepaintResult: Sendable {
    public let variable: String
    public let sectionName: String
}

/// Result of a render operation
public struct RenderResult: Sendable, Equatable {
    public let content: String
}


