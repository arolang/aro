// ============================================================
// ActionDescriptors.swift
// ARO Runtime - Action Descriptors
// ============================================================

import Foundation
import AROParser

// MARK: - Result Descriptor

/// Describes the result part of an ARO statement
///
/// In `<Extract> the <user: identifier> from the <request>`, the result descriptor
/// represents `<user: identifier>` with base="user" and specifiers=["identifier"].
public struct ResultDescriptor: Sendable, Equatable, CustomStringConvertible {
    /// The base name (variable name to bind)
    public let base: String

    /// Type specifiers from the qualified noun
    public let specifiers: [String]

    /// Source location for error reporting
    public let span: SourceSpan

    /// Full qualified name for display
    public var fullName: String {
        specifiers.isEmpty ? base : "\(base): \(specifiers.joined(separator: "."))"
    }

    /// Initialize from AST QualifiedNoun
    public init(from qualifiedNoun: QualifiedNoun) {
        self.base = qualifiedNoun.base
        self.specifiers = qualifiedNoun.specifiers
        self.span = qualifiedNoun.span
    }

    /// Initialize with explicit values
    public init(base: String, specifiers: [String] = [], span: SourceSpan) {
        self.base = base
        self.specifiers = specifiers
        self.span = span
    }

    public var description: String {
        "<\(fullName)>"
    }
}

// MARK: - Object Descriptor

/// Describes the object part of an ARO statement
///
/// In `<Extract> the <user> from the <request: parameters>`, the object descriptor
/// represents `from the <request: parameters>` with preposition=.from, base="request",
/// and specifiers=["parameters"].
public struct ObjectDescriptor: Sendable, Equatable, CustomStringConvertible {
    /// The preposition connecting action to object
    public let preposition: Preposition

    /// The base name (source variable/resource)
    public let base: String

    /// Type specifiers from the qualified noun
    public let specifiers: [String]

    /// Source location for error reporting
    public let span: SourceSpan

    /// Whether this references an external source
    public var isExternalReference: Bool {
        preposition.indicatesExternalSource
    }

    /// Full qualified name for display
    public var fullName: String {
        specifiers.isEmpty ? base : "\(base): \(specifiers.joined(separator: "."))"
    }

    /// Key path for nested access (e.g., "request.parameters.userId")
    public var keyPath: String {
        if specifiers.isEmpty {
            return base
        }
        return "\(base).\(specifiers.joined(separator: "."))"
    }

    /// Initialize from AST ObjectClause
    public init(from objectClause: ObjectClause) {
        self.preposition = objectClause.preposition
        self.base = objectClause.noun.base
        self.specifiers = objectClause.noun.specifiers
        self.span = objectClause.noun.span
    }

    /// Initialize with explicit values
    public init(preposition: Preposition, base: String, specifiers: [String] = [], span: SourceSpan) {
        self.preposition = preposition
        self.base = base
        self.specifiers = specifiers
        self.span = span
    }

    public var description: String {
        "\(preposition.rawValue) the <\(fullName)>"
    }
}

// MARK: - Statement Descriptor

/// Complete descriptor for an ARO statement ready for execution
public struct StatementDescriptor: Sendable {
    /// The action verb
    public let verb: String

    /// The action's semantic role
    public let role: ActionRole

    /// The result to be produced
    public let result: ResultDescriptor

    /// The object/source to use
    public let object: ObjectDescriptor

    /// Initialize from an AST AROStatement
    public init(from statement: AROStatement) {
        self.verb = statement.action.verb
        self.role = ActionRole(from: statement.action.semanticRole)
        self.result = ResultDescriptor(from: statement.result)
        self.object = ObjectDescriptor(from: statement.object)
    }

    /// Initialize with explicit values
    public init(verb: String, role: ActionRole, result: ResultDescriptor, object: ObjectDescriptor) {
        self.verb = verb
        self.role = role
        self.result = result
        self.object = object
    }
}
