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
    /// `"""…"""` was removed (GitLab #524). Kept as a case of its own so
    /// the diagnostic names the replacement instead of leaving the lexer
    /// to read `"""` as two empty strings and cascade from there.
    case tripleQuotedStringRemoved(at: SourceLocation)

    public var location: SourceLocation? {
        switch self {
        case .unexpectedCharacter(_, let loc): return loc
        case .unterminatedString(let loc): return loc
        case .invalidEscapeSequence(_, let loc): return loc
        case .invalidNumber(_, let loc): return loc
        case .invalidUnicodeEscape(_, let loc): return loc
        case .tripleQuotedStringRemoved(let loc): return loc
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
        case .tripleQuotedStringRemoved:
            return "Triple-quoted strings were removed — a plain \"…\" string spans multiple lines"
        }
    }

    /// The same error reported at `location` instead of where it was raised.
    ///
    /// Used when a sub-lexer runs over a slice of a document — the inside of a
    /// `${…}` interpolation — and its locations are relative to that slice.
    /// Without this the error points at line 1 of a fragment nobody can see
    /// (GitLab #659).
    public func relocated(to location: SourceLocation) -> LexerError {
        switch self {
        case .unexpectedCharacter(let char, _): return .unexpectedCharacter(char, at: location)
        case .unterminatedString: return .unterminatedString(at: location)
        case .invalidEscapeSequence(let char, _): return .invalidEscapeSequence(char, at: location)
        case .invalidNumber(let num, _): return .invalidNumber(num, at: location)
        case .invalidUnicodeEscape(let hex, _): return .invalidUnicodeEscape(hex, at: location)
        case .tripleQuotedStringRemoved: return .tripleQuotedStringRemoved(at: location)
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
    /// Parsing recovered from one or more errors and the caller has no
    /// collector to read them from (GitLab #543). Carries every
    /// diagnostic so nothing is lost by the time it surfaces.
    case recovered(errors: [Diagnostic])

    public var location: SourceLocation? {
        switch self {
        case .unexpectedToken(_, let token): return token.span.start
        case .unexpectedEndOfFile: return nil
        case .invalidStatement(let loc): return loc
        case .missingFeatureSetName(let loc): return loc
        case .missingBusinessActivity(let loc): return loc
        case .invalidQualifiedNoun(let loc): return loc
        case .emptyFeatureSet(let loc): return loc
        case .recovered(let errors): return errors.first?.location
        }
    }
    
    public var message: String {
        switch self {
        case .unexpectedToken(let expected, let got):
            // A reserved word is named as one (GitLab #548): "but got empty"
            // read like a rejected identifier, which sent readers looking for a
            // typo instead of for the keyword they had used as a name.
            if got.kind.isKeyword {
                return "Expected \(expected), but got the keyword '\(got.kind)'"
            }
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
        case .recovered(let errors):
            // Lead with the first error — the one worth acting on
            // after ranking — and say how many more there are, so a
            // single-line log is still honest about the rest.
            guard let first = errors.first else { return "Parsing failed" }
            let extra = errors.count - 1
            return extra > 0
                ? "\(first.message) (and \(extra) more parse error\(extra == 1 ? "" : "s"))"
                : first.message
        case .emptyFeatureSet:
            return "Feature set must contain at least one statement"
        }
    }

    /// Context-specific recovery hint for this error, shown after the message
    public var hint: String? {
        switch self {
        case .unexpectedToken(let expected, _):
            if expected == "'.'" {
                return "Statements must end with a period (.)"
            }
            if expected.contains("object") || expected.contains("'<'") {
                return "Object identifiers must be wrapped in angle brackets: <identifier>"
            }
            if expected.contains("identifier") {
                return "Expected an identifier (letters, digits, or hyphens)"
            }
            return nil
        case .unexpectedEndOfFile:
            return "The file ended unexpectedly — check for unclosed braces or missing statements"
        case .emptyFeatureSet:
            return "Add at least one statement inside the feature set body"
        default:
            return nil
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

    /// Whether this diagnostic names the problem itself or a symptom of it.
    ///
    /// A statement that fails semantic analysis leaves debris behind: its
    /// result is "defined but never used" (nothing downstream could use it),
    /// and the feature set "has no Return or Throw" (the terminator never
    /// analyzed cleanly). Front-ends that show only the first line — Jupyter's
    /// `evalue`, a notebook cell — were surfacing that debris while the real
    /// error sat lower in the list (GitLab #509). Tagging the debris as
    /// `.consequential` lets `ranked()` keep root causes on top.
    public enum Category: String, Sendable {
        /// The diagnostic names an actual problem in the source.
        case rootCause
        /// The diagnostic is plausible fallout of another diagnostic —
        /// hygiene findings like unused-variable or missing-return that a
        /// failed statement produces as a side effect.
        case consequential
    }

    public let severity: Severity
    public let message: String
    public let location: SourceLocation?
    public let hints: [String]
    public let category: Category

    public init(
        severity: Severity,
        message: String,
        location: SourceLocation? = nil,
        hints: [String] = [],
        category: Category = .rootCause
    ) {
        self.severity = severity
        self.message = message
        self.location = location
        self.hints = hints
        self.category = category
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

extension Array where Element == Diagnostic {
    /// The same diagnostics, root causes first (GitLab #509).
    ///
    /// Order: errors before warnings before notes; within a severity,
    /// `.rootCause` before `.consequential`; within a class, emission order
    /// is preserved (the sort is made stable by index). Nothing is dropped
    /// or reworded — only the headline changes, so a front-end showing one
    /// line shows the diagnostic worth acting on.
    public func ranked() -> [Diagnostic] {
        func severityRank(_ s: Diagnostic.Severity) -> Int {
            switch s {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }
        func categoryRank(_ c: Diagnostic.Category) -> Int {
            switch c {
            case .rootCause: return 0
            case .consequential: return 1
            }
        }
        return self.enumerated()
            .sorted { lhs, rhs in
                let l = (severityRank(lhs.element.severity), categoryRank(lhs.element.category), lhs.offset)
                let r = (severityRank(rhs.element.severity), categoryRank(rhs.element.category), rhs.offset)
                return l < r
            }
            .map(\.element)
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
    
    public func error(
        _ message: String,
        at location: SourceLocation? = nil,
        hints: [String] = [],
        category: Diagnostic.Category = .rootCause
    ) {
        add(Diagnostic(severity: .error, message: message, location: location, hints: hints, category: category))
    }

    public func warning(
        _ message: String,
        at location: SourceLocation? = nil,
        hints: [String] = [],
        category: Diagnostic.Category = .rootCause
    ) {
        add(Diagnostic(severity: .warning, message: message, location: location, hints: hints, category: category))
    }
    
    public func note(_ message: String, at location: SourceLocation? = nil) {
        add(Diagnostic(severity: .note, message: message, location: location))
    }
    
    public func report(_ error: any CompilerError) {
        if let parserError = error as? ParserError, let hint = parserError.hint {
            add(Diagnostic(severity: .error, message: error.message, location: error.location, hints: [hint]))
        } else {
            add(.from(error))
        }
    }
}
