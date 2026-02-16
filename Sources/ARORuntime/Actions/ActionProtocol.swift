// ============================================================
// ActionProtocol.swift
// ARO Runtime - Action Implementation Protocol
// ============================================================

import Foundation
import AROParser

// MARK: - Action Role

/// Semantic classification of actions matching AROParser's ActionSemanticRole
public enum ActionRole: String, Sendable, CaseIterable {
    case request    // External -> Internal (Extract, Retrieve, Receive)
    case own        // Internal -> Internal (Compute, Validate, Compare)
    case response   // Internal -> External (Return, Throw, Send)
    case export     // Publish mechanism
    case server     // Server/service operations (Start, Stop, Connect, Close)

    /// Convert from parser's ActionSemanticRole
    public init(from parserRole: ActionSemanticRole) {
        switch parserRole {
        case .request: self = .request
        case .own: self = .own
        case .response: self = .response
        case .export: self = .export
        case .server: self = .server
        }
    }
}

// MARK: - Action Implementation Protocol

/// Protocol for all action implementations
///
/// Actions are the executable units of ARO. Each action verb (Extract, Compute, Return, etc.)
/// is bound to an implementation conforming to this protocol.
///
/// ## Example
/// ```swift
/// public struct ExtractAction: ActionImplementation {
///     public static let role: ActionRole = .request
///     public static let verbs: Set<String> = ["extract", "parse", "get"]
///     public static let validPrepositions: Set<Preposition> = [.from, .via]
///
///     public init() {}
///
///     public func execute(
///         result: ResultDescriptor,
///         object: ObjectDescriptor,
///         context: ExecutionContext
///     ) async throws -> any Sendable {
///         // Implementation
///     }
/// }
/// ```
public protocol ActionImplementation: Sendable {
    /// The semantic role of this action
    static var role: ActionRole { get }

    /// Verbs that trigger this action (lowercase)
    static var verbs: Set<String> { get }

    /// Valid prepositions for this action
    static var validPrepositions: Set<Preposition> { get }

    /// Default initializer (actions should be stateless)
    init()

    /// Execute the action asynchronously
    /// - Parameters:
    ///   - result: Describes the output variable to be created
    ///   - object: Describes the input source
    ///   - context: Runtime execution context for variable binding and service access
    /// - Returns: The produced value to be bound to the result variable
    func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable
}

// MARK: - Default Implementations

public extension ActionImplementation {
    /// Validate that the preposition is allowed for this action
    func validatePreposition(_ prep: Preposition) throws {
        guard Self.validPrepositions.contains(prep) else {
            throw ActionError.invalidPreposition(
                action: String(describing: Self.self),
                received: prep,
                expected: Self.validPrepositions
            )
        }
    }

    /// Check if this action handles a given verb
    static func handles(verb: String) -> Bool {
        verbs.contains(verb.lowercased())
    }

    // MARK: - Type-Safe Value Extraction

    /// Resolve a typed value from context
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The TypedValue if found, nil otherwise
    func resolveTyped(_ name: String, from context: ExecutionContext) -> TypedValue? {
        context.resolveTyped(name)
    }

    /// Require a string value, throwing on missing or type mismatch
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The string value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireString(_ name: String, from context: ExecutionContext) throws -> String {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let str = typed.asString() else {
            throw ActionError.typeMismatch(
                expected: "String",
                actual: typed.type.description,
                variable: name
            )
        }
        return str
    }

    /// Require an integer value, throwing on missing or type mismatch
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The integer value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireInt(_ name: String, from context: ExecutionContext) throws -> Int {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let i = typed.asInt() else {
            throw ActionError.typeMismatch(
                expected: "Integer",
                actual: typed.type.description,
                variable: name
            )
        }
        return i
    }

    /// Require a double/float value, throwing on missing or type mismatch
    /// Also accepts Int and converts to Double
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The double value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireDouble(_ name: String, from context: ExecutionContext) throws -> Double {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let d = typed.asDouble() else {
            throw ActionError.typeMismatch(
                expected: "Float",
                actual: typed.type.description,
                variable: name
            )
        }
        return d
    }

    /// Require a boolean value, throwing on missing or type mismatch
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The boolean value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireBool(_ name: String, from context: ExecutionContext) throws -> Bool {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let b = typed.asBool() else {
            throw ActionError.typeMismatch(
                expected: "Boolean",
                actual: typed.type.description,
                variable: name
            )
        }
        return b
    }

    /// Require a list/array value, throwing on missing or type mismatch
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The array value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireList(_ name: String, from context: ExecutionContext) throws -> [any Sendable] {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let arr = typed.asList() else {
            throw ActionError.typeMismatch(
                expected: "List",
                actual: typed.type.description,
                variable: name
            )
        }
        return arr
    }

    /// Require a dictionary/map value, throwing on missing or type mismatch
    /// - Parameters:
    ///   - name: Variable name to resolve
    ///   - context: The execution context
    /// - Returns: The dictionary value
    /// - Throws: ActionError.undefinedVariable or ActionError.typeMismatch
    func requireDict(_ name: String, from context: ExecutionContext) throws -> [String: any Sendable] {
        guard let typed = context.resolveTyped(name) else {
            throw ActionError.undefinedVariable(name)
        }
        guard let dict = typed.asDict() else {
            throw ActionError.typeMismatch(
                expected: "Map",
                actual: typed.type.description,
                variable: name
            )
        }
        return dict
    }
}
