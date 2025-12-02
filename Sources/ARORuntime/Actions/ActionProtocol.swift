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

    /// Convert from parser's ActionSemanticRole
    public init(from parserRole: ActionSemanticRole) {
        switch parserRole {
        case .request: self = .request
        case .own: self = .own
        case .response: self = .response
        case .export: self = .export
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
}
