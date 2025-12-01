// ============================================================
// Parser.swift
// ARO Parser - Recursive Descent Parser
// ============================================================

import Foundation

/// Parses tokens into an Abstract Syntax Tree
public final class Parser {
    
    // MARK: - Properties
    
    private let tokens: [Token]
    private var current: Int = 0
    private let diagnostics: DiagnosticCollector
    
    // MARK: - Initialization
    
    public init(tokens: [Token], diagnostics: DiagnosticCollector = DiagnosticCollector()) {
        self.tokens = tokens
        self.diagnostics = diagnostics
    }
    
    // MARK: - Public Interface
    
    /// Parses the tokens into a Program AST
    public func parse() throws -> Program {
        let startSpan = peek().span
        var featureSets: [FeatureSet] = []

        while !isAtEnd {
            do {
                let featureSet = try parseFeatureSet()
                featureSets.append(featureSet)
            } catch let error as ParserError {
                diagnostics.report(error)
                synchronize()
            }
        }

        // Use startSpan if we haven't advanced (empty program)
        let endSpan = current > 0 ? previous().span : startSpan
        return Program(
            featureSets: featureSets,
            span: startSpan.merged(with: endSpan)
        )
    }
    
    // MARK: - Feature Set Parsing
    
    /// Parses: "(" name ":" activity ")" "{" { statement } "}"
    private func parseFeatureSet() throws -> FeatureSet {
        let startToken = try expect(.leftParen, message: "'('")
        
        // Parse feature set name (space-separated identifiers)
        let name = try parseIdentifierSequence()
        if name.isEmpty {
            throw ParserError.missingFeatureSetName(at: peek().span.start)
        }
        
        try expect(.colon, message: "':'")
        
        // Parse business activity (space-separated identifiers)
        let activity = try parseIdentifierSequence()
        if activity.isEmpty {
            throw ParserError.missingBusinessActivity(at: peek().span.start)
        }
        
        try expect(.rightParen, message: "')'")
        try expect(.leftBrace, message: "'{'")
        
        // Parse statements
        var statements: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            do {
                let statement = try parseStatement()
                statements.append(statement)
            } catch let error as ParserError {
                diagnostics.report(error)
                synchronizeToNextStatement()
            }
        }
        
        let endToken = try expect(.rightBrace, message: "'}'")
        
        return FeatureSet(
            name: name,
            businessActivity: activity,
            statements: statements,
            span: startToken.span.merged(with: endToken.span)
        )
    }
    
    // MARK: - Statement Parsing
    
    /// Parses a statement (ARO or Publish)
    private func parseStatement() throws -> Statement {
        let startToken = try expect(.leftAngle, message: "'<'")
        
        // Check if this is a publish statement
        if check(.publish) {
            return try parsePublishStatement(startToken: startToken)
        }
        
        return try parseAROStatement(startToken: startToken)
    }
    
    /// Parses: "<" action ">" [article] "<" result ">" preposition [article] "<" object ">" "."
    private func parseAROStatement(startToken: Token) throws -> AROStatement {
        // Parse action verb
        let actionToken = try expectIdentifier(message: "action verb")
        let action = Action(verb: actionToken.lexeme, span: actionToken.span)
        try expect(.rightAngle, message: "'>'")
        
        // Skip optional article before result
        if case .article = peek().kind {
            advance()
        }
        
        // Parse result
        try expect(.leftAngle, message: "'<'")
        let result = try parseQualifiedNoun()
        try expect(.rightAngle, message: "'>'")
        
        // Parse preposition
        // Note: "for" is lexed as .for keyword (for iteration) but also used as a preposition
        let prep: Preposition
        if case .preposition(let p) = peek().kind {
            prep = p
            advance()
        } else if case .for = peek().kind {
            // Accept "for" keyword as the preposition .for
            prep = .for
            advance()
        } else {
            throw ParserError.unexpectedToken(expected: "preposition", got: peek())
        }

        // After preposition, we can have:
        // 1. [article] <object> [with literal] - standard syntax
        // 2. literal - when preposition is 'with', the literal IS the object
        var objectNoun: QualifiedNoun
        var literalValue: LiteralValue? = nil

        // Check if the next token is a literal (for `with "literal"` syntax)
        if prep == .with && isLiteralToken(peek()) {
            // `with "literal"` - literal is the object
            literalValue = try parseLiteralValue()
            // Create a placeholder object noun for the literal
            objectNoun = QualifiedNoun(base: "_literal_", specifiers: [], span: previous().span)
        } else {
            // Standard syntax: [article] <object>
            // Skip optional article before object
            if case .article = peek().kind {
                advance()
            }

            // Parse object
            try expect(.leftAngle, message: "'<'")
            objectNoun = try parseQualifiedNoun()
            try expect(.rightAngle, message: "'>'")

            // Parse optional literal value: `with "string"` or `with 42`
            if case .preposition(.with) = peek().kind {
                advance() // consume 'with'
                literalValue = try parseLiteralValue()
            }
        }

        let endToken = try expect(.dot, message: "'.'")

        return AROStatement(
            action: action,
            result: result,
            object: ObjectClause(preposition: prep, noun: objectNoun),
            literalValue: literalValue,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Check if the token is a literal value
    private func isLiteralToken(_ token: Token) -> Bool {
        switch token.kind {
        case .stringLiteral, .intLiteral, .floatLiteral, .true, .false, .nil, .null:
            return true
        default:
            return false
        }
    }

    /// Parses a literal value (string, number, boolean, null)
    private func parseLiteralValue() throws -> LiteralValue {
        let token = peek()
        switch token.kind {
        case .stringLiteral(let s):
            advance()
            return .string(s)
        case .intLiteral(let i):
            advance()
            return .integer(i)
        case .floatLiteral(let f):
            advance()
            return .float(f)
        case .true:
            advance()
            return .boolean(true)
        case .false:
            advance()
            return .boolean(false)
        case .nil, .null:
            advance()
            return .null
        default:
            throw ParserError.unexpectedToken(expected: "literal value", got: token)
        }
    }
    
    /// Parses: "<Publish>" "as" "<" external ">" "<" internal ">" "."
    private func parsePublishStatement(startToken: Token) throws -> PublishStatement {
        advance() // consume 'Publish'
        try expect(.rightAngle, message: "'>'")
        
        try expect(.as, message: "'as'")
        
        try expect(.leftAngle, message: "'<'")
        let externalName = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")
        
        try expect(.leftAngle, message: "'<'")
        let internalVariable = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")
        
        let endToken = try expect(.dot, message: "'.'")
        
        return PublishStatement(
            externalName: externalName,
            internalVariable: internalVariable,
            span: startToken.span.merged(with: endToken.span)
        )
    }
    
    // MARK: - Qualified Noun Parsing
    
    /// Parses: base [ ":" specifier { specifier } ]
    private func parseQualifiedNoun() throws -> QualifiedNoun {
        let startToken = peek()
        let base = try parseCompoundIdentifier()
        var specifiers: [String] = []
        
        if check(.colon) {
            advance()
            
            // Parse space-separated specifiers
            while peek().kind.isIdentifier {
                specifiers.append(try parseCompoundIdentifier())
            }
        }
        
        return QualifiedNoun(
            base: base,
            specifiers: specifiers,
            span: startToken.span.merged(with: previous().span)
        )
    }
    
    /// Parses: identifier { "-" identifier }
    private func parseCompoundIdentifier() throws -> String {
        var result = try expectIdentifier(message: "identifier").lexeme
        
        while check(.hyphen) {
            advance()
            result += "-"
            result += try expectIdentifier(message: "identifier after '-'").lexeme
        }
        
        return result
    }
    
    /// Parses space-separated compound identifiers as a single string
    /// Each compound identifier can contain hyphens (e.g., "Application-Start Entry Point")
    private func parseIdentifierSequence() throws -> String {
        var parts: [String] = []

        while peek().kind.isIdentifier {
            // Parse compound identifier (handles hyphens)
            var compound = advance().lexeme
            while check(.hyphen) {
                advance()
                compound += "-"
                if peek().kind.isIdentifier {
                    compound += advance().lexeme
                } else {
                    // Put back the hyphen conceptually by breaking
                    // (trailing hyphen without identifier is invalid)
                    break
                }
            }
            parts.append(compound)
        }

        return parts.joined(separator: " ")
    }
    
    // MARK: - Token Access
    
    private func peek() -> Token {
        tokens[current]
    }
    
    private func previous() -> Token {
        tokens[current - 1]
    }
    
    @discardableResult
    private func advance() -> Token {
        if !isAtEnd {
            current += 1
        }
        return previous()
    }
    
    private var isAtEnd: Bool {
        peek().kind == .eof
    }
    
    private func check(_ kind: TokenKind) -> Bool {
        if isAtEnd { return false }
        return peek().kind == kind
    }
    
    // MARK: - Expectations
    
    @discardableResult
    private func expect(_ kind: TokenKind, message: String) throws -> Token {
        if check(kind) {
            return advance()
        }
        throw ParserError.unexpectedToken(expected: message, got: peek())
    }
    
    private func expectIdentifier(message: String) throws -> Token {
        let token = peek()
        // Accept identifier tokens
        if token.kind.isIdentifier {
            return advance()
        }
        // Also accept articles (a, an, the) as identifiers when inside <...>
        // This allows <a>, <an>, <the> as valid variable names
        if case .article = token.kind {
            return advance()
        }
        throw ParserError.unexpectedToken(expected: message, got: token)
    }
    
    // MARK: - Error Recovery
    
    /// Synchronizes to the next feature set after an error
    private func synchronize() {
        while !isAtEnd {
            // Look for the start of a new feature set
            if check(.leftParen) {
                return
            }
            advance()
        }
    }
    
    /// Synchronizes to the next statement after an error
    private func synchronizeToNextStatement() {
        while !isAtEnd {
            // If we just passed a dot, we're at the start of a new statement
            if previous().kind == .dot {
                return
            }
            
            // If we see a closing brace, stop
            if check(.rightBrace) {
                return
            }
            
            // If we see an opening angle bracket, we might be at a new statement
            if check(.leftAngle) {
                return
            }
            
            advance()
        }
    }
}

// MARK: - Convenience Extension

extension Parser {
    /// Creates a parser from source code and parses it
    public static func parse(_ source: String, diagnostics: DiagnosticCollector = DiagnosticCollector()) throws -> Program {
        let tokens = try Lexer.tokenize(source)
        return try Parser(tokens: tokens, diagnostics: diagnostics).parse()
    }
}
