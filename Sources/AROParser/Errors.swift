// ============================================================
// Errors.swift
// ARO Parser - Error Definitions
// ============================================================

import Foundation

// MARK: - Compiler Error Protocol

/// Base protocol for all compiler errors
public protocol CompilerError: Error, Sendable, CustomStringConvertible {
    var location: SourceLocation? { get }
    var message: String { get }
}

extension CompilerError {
    public var description: String {
        if let loc = location {
            return "[\(loc)] \(message)"
        }
        return message
    }
}

// MARK: - Lexer Errors

/// Errors that occur during lexical analysis
public enum LexerError: CompilerError {
    case unexpectedCharacter(Character, at: SourceLocation)
    case unterminatedString(at: SourceLocation)
    case invalidEscapeSequence(Character, at: SourceLocation)
    case invalidNumber(String, at: SourceLocation)
    case invalidUnicodeEscape(String, at: SourceLocation)

    public var location: SourceLocation? {
        switch self {
        case .unexpectedCharacter(_, let loc): return loc
        case .unterminatedString(let loc): return loc
        case .invalidEscapeSequence(_, let loc): return loc
        case .invalidNumber(_, let loc): return loc
        case .invalidUnicodeEscape(_, let loc): return loc
        }
    }

    public var message: String {
        switch self {
        case .unexpectedCharacter(let char, _):
            return "Unexpected character '\(char)'"
        case .unterminatedString:
            return "Unterminated string literal"
        case .invalidEscapeSequence(let char, _):
            return "Invalid escape sequence '\\(\(char))'"
        case .invalidNumber(let num, _):
            return "Invalid number literal '\(num)'"
        case .invalidUnicodeEscape(let hex, _):
            return "Invalid unicode escape sequence '\\u{\(hex)}'"
        }
    }
}

// MARK: - Parser Errors

/// Errors that occur during parsing
public enum ParserError: CompilerError {
    case unexpectedToken(expected: String, got: Token)
    case unexpectedEndOfFile(expected: String)
    case invalidStatement(at: SourceLocation)
    case missingFeatureSetName(at: SourceLocation)
    case missingBusinessActivity(at: SourceLocation)
    case invalidQualifiedNoun(at: SourceLocation)
    case emptyFeatureSet(at: SourceLocation)
    
    public var location: SourceLocation? {
        switch self {
        case .unexpectedToken(_, let token): return token.span.start
        case .unexpectedEndOfFile: return nil
        case .invalidStatement(let loc): return loc
        case .missingFeatureSetName(let loc): return loc
        case .missingBusinessActivity(let loc): return loc
        case .invalidQualifiedNoun(let loc): return loc
        case .emptyFeatureSet(let loc): return loc
        }
    }
    
    public var message: String {
        switch self {
        case .unexpectedToken(let expected, let got):
            return "Expected \(expected), but got \(got.kind)"
        case .unexpectedEndOfFile(let expected):
            return "Unexpected end of file, expected \(expected)"
        case .invalidStatement:
            return "Invalid statement"
        case .missingFeatureSetName:
            return "Missing feature set name"
        case .missingBusinessActivity:
            return "Missing business activity"
        case .invalidQualifiedNoun:
            return "Invalid qualified noun"
        case .emptyFeatureSet:
            return "Feature set must contain at least one statement"
        }
    }
}

// MARK: - Semantic Errors

/// Errors that occur during semantic analysis
public enum SemanticError: CompilerError {
    case undefinedVariable(name: String, at: SourceLocation)
    case duplicateDefinition(name: String, original: SourceLocation, duplicate: SourceLocation)
    case undefinedExternalDependency(name: String, at: SourceLocation)
    case circularDependency(variables: [String], at: SourceLocation)
    case invalidPublish(variable: String, at: SourceLocation)
    case typeError(expected: String, got: String, at: SourceLocation)
    
    public var location: SourceLocation? {
        switch self {
        case .undefinedVariable(_, let loc): return loc
        case .duplicateDefinition(_, _, let loc): return loc
        case .undefinedExternalDependency(_, let loc): return loc
        case .circularDependency(_, let loc): return loc
        case .invalidPublish(_, let loc): return loc
        case .typeError(_, _, let loc): return loc
        }
    }
    
    public var message: String {
        switch self {
        case .undefinedVariable(let name, _):
            return "Undefined variable '\(name)'"
        case .duplicateDefinition(let name, let original, _):
            return "Duplicate definition of '\(name)' (originally defined at \(original))"
        case .undefinedExternalDependency(let name, _):
            return "Undefined external dependency '\(name)'"
        case .circularDependency(let vars, _):
            return "Circular dependency detected: \(vars.joined(separator: " -> "))"
        case .invalidPublish(let variable, _):
            return "Cannot publish undefined variable '\(variable)'"
        case .typeError(let expected, let got, _):
            return "Type error: expected \(expected), got \(got)"
        }
    }
}

// MARK: - Diagnostic

/// A diagnostic message (error, warning, or note)
public struct Diagnostic: Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case error
        case warning
        case note
    }
    
    public let severity: Severity
    public let message: String
    public let location: SourceLocation?
    public let hints: [String]
    
    public init(
        severity: Severity,
        message: String,
        location: SourceLocation? = nil,
        hints: [String] = []
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.hints = hints
    }
    
    public var description: String {
        var result = "\(severity.rawValue)"
        if let loc = location {
            result += " [\(loc)]"
        }
        result += ": \(message)"
        for hint in hints {
            result += "\n  hint: \(hint)"
        }
        return result
    }
    
    /// Creates an error diagnostic from a compiler error
    public static func from(_ error: any CompilerError) -> Diagnostic {
        Diagnostic(severity: .error, message: error.message, location: error.location)
    }
}

// MARK: - Diagnostic Collection

/// Collects diagnostics during compilation
public final class DiagnosticCollector: @unchecked Sendable {
    private var _diagnostics: [Diagnostic] = []
    private let lock = NSLock()
    
    public init() {}
    
    public var diagnostics: [Diagnostic] {
        lock.lock()
        defer { lock.unlock() }
        return _diagnostics
    }
    
    public var hasErrors: Bool {
        diagnostics.contains { $0.severity == .error }
    }
    
    public var errors: [Diagnostic] {
        diagnostics.filter { $0.severity == .error }
    }
    
    public var warnings: [Diagnostic] {
        diagnostics.filter { $0.severity == .warning }
    }
    
    public func add(_ diagnostic: Diagnostic) {
        lock.lock()
        defer { lock.unlock() }
        _diagnostics.append(diagnostic)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        _diagnostics.removeAll()
    }
    
    public func error(_ message: String, at location: SourceLocation? = nil, hints: [String] = []) {
        add(Diagnostic(severity: .error, message: message, location: location, hints: hints))
    }
    
    public func warning(_ message: String, at location: SourceLocation? = nil, hints: [String] = []) {
        add(Diagnostic(severity: .warning, message: message, location: location, hints: hints))
    }
    
    public func note(_ message: String, at location: SourceLocation? = nil) {
        add(Diagnostic(severity: .note, message: message, location: location))
    }
    
    public func report(_ error: any CompilerError) {
        add(.from(error))
    }
}
