// ============================================================
// TokenStream.swift
// ARO Parser - Token Stream Management
// ============================================================
// GitLab #99: Modularize Parser into smaller components
// ============================================================

import Foundation

/// Protocol for token stream navigation and lookahead
/// Provides common operations for recursive descent parsing
protocol TokenStream {
    /// Current position in token stream
    var current: Int { get set }

    /// All tokens in the stream
    var tokens: [Token] { get }

    /// Peek at the current token without consuming it
    func peek() -> Token

    /// Peek at the previous token
    func previous() -> Token

    /// Advance to the next token and return the previous one
    @discardableResult
    mutating func advance() -> Token

    /// Check if we're at the end of the stream
    var isAtEnd: Bool { get }

    /// Check if current token matches the given kind
    func check(_ kind: TokenKind) -> Bool

    /// Expect a token of the given kind, consume and return it
    /// Throws if token doesn't match
    @discardableResult
    func expect(_ kind: TokenKind, message: String) throws -> Token

    /// Expect an identifier-like token, consume and return it
    /// Throws if not an identifier
    func expectIdentifier(message: String) throws -> Token
}

// Note: Default implementations are provided in Parser class
// This protocol documents the token stream interface for future modularization

/// Error recovery utilities for parsers
protocol ErrorRecovery {
    /// Diagnostics collector for error reporting
    var diagnostics: DiagnosticCollector { get }

    /// Synchronize to the next feature set after an error
    func synchronize()

    /// Synchronize to the next statement after an error
    func synchronizeToNextStatement()
}
