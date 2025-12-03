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
        var imports: [ImportDeclaration] = []
        var featureSets: [FeatureSet] = []

        // Parse import declarations (ARO-0007) - must come before feature sets
        while check(.import) {
            do {
                let importDecl = try parseImportDeclaration()
                imports.append(importDecl)
            } catch let error as ParserError {
                diagnostics.report(error)
                synchronize()
            }
        }

        // Parse feature sets
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
            imports: imports,
            featureSets: featureSets,
            span: startSpan.merged(with: endSpan)
        )
    }

    // MARK: - Import Declaration Parsing (ARO-0007)

    /// Parses: "import" path
    /// Path can be: ../folder, ./folder, ../../path/to/app
    private func parseImportDeclaration() throws -> ImportDeclaration {
        let startToken = try expect(.import, message: "'import'")

        // Parse the path - it's a sequence of identifiers, dots, and slashes
        var path = ""

        // Path starts with ./ or ../ or identifier
        while !isAtEnd && !check(.leftParen) && !check(.import) {
            let token = peek()
            switch token.kind {
            case .dot:
                path += "."
                advance()
            case .slash:
                path += "/"
                advance()
            case .identifier(let name):
                path += name
                advance()
            case .hyphen:
                path += "-"
                advance()
            default:
                // End of path
                break
            }
            // Break if we hit something that's not part of a path
            if case .leftParen = peek().kind { break }
            if case .import = peek().kind { break }
            if case .eof = peek().kind { break }
            // Check if we've stopped making progress (no more path chars)
            let nextToken = peek()
            if case .dot = nextToken.kind { continue }
            if case .slash = nextToken.kind { continue }
            if case .identifier = nextToken.kind { continue }
            if case .hyphen = nextToken.kind { continue }
            break
        }

        if path.isEmpty {
            throw ParserError.unexpectedToken(expected: "import path", got: peek())
        }

        return ImportDeclaration(
            path: path,
            span: startToken.span.merged(with: previous().span)
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

    /// Parses a statement (ARO, Publish, Require, Match, or ForEach)
    private func parseStatement() throws -> Statement {
        // Check for match statement (ARO-0004) - starts with 'match' keyword
        if check(.match) {
            return try parseMatchStatement()
        }

        // Check for for-each loop (ARO-0005) - starts with 'for' or 'parallel for'
        if check(.for) {
            return try parseForEachLoop(isParallel: false)
        }
        if check(.parallel) {
            return try parseParallelForEachLoop()
        }

        let startToken = try expect(.leftAngle, message: "'<'")

        // Check if this is a publish statement
        if check(.publish) {
            return try parsePublishStatement(startToken: startToken)
        }

        // Check if this is a require statement (ARO-0003)
        if check(.require) {
            return try parseRequireStatement(startToken: startToken)
        }

        return try parseAROStatement(startToken: startToken)
    }
    
    /// Parses: "<" action ">" [article] "<" result ">" preposition [article] "<" object ">" ["when" condition] "."
    /// ARO-0002: Also supports expressions after prepositions like `from <x> * <y>` or `to 30`
    /// ARO-0004: Also supports guarded statements with `when` clause
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
        // 1. [article] <object> [with literal/expression] - standard syntax
        // 2. expression - for computed values like `from <x> * <y>` or `to 30`
        var objectNoun: QualifiedNoun
        var literalValue: LiteralValue? = nil
        var expression: (any Expression)? = nil

        // Check if we should parse an expression after the preposition
        // This happens for: `to <expr>`, `from <expr>`, `with <expr>`, `for <expr>` when followed by expression-starting token
        let shouldParseExpression = (prep == .to || prep == .from || prep == .with || prep == .for) && isExpressionStart(peek())

        if shouldParseExpression && !isArticleFollowedByAngle() {
            // Parse expression (ARO-0002)
            expression = try parseExpression()
            // Create a placeholder object noun for the expression
            objectNoun = QualifiedNoun(base: "_expression_", specifiers: [], span: previous().span)
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

            // Parse optional value after object: `with "string"` or `with <expr>`
            if case .preposition(.with) = peek().kind {
                advance() // consume 'with'
                if isExpressionStart(peek()) {
                    // Try to parse as expression first
                    expression = try parseExpression()
                }
            }
        }

        // Parse optional when clause (ARO-0004): `when <condition>`
        var whenCondition: (any Expression)?
        if check(.when) {
            advance() // consume 'when'
            whenCondition = try parseExpression()
        }

        let endToken = try expect(.dot, message: "'.'")

        return AROStatement(
            action: action,
            result: result,
            object: ObjectClause(preposition: prep, noun: objectNoun),
            literalValue: literalValue,
            expression: expression,
            whenCondition: whenCondition,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Check if the token could start an expression
    private func isExpressionStart(_ token: Token) -> Bool {
        switch token.kind {
        case .stringLiteral, .intLiteral, .floatLiteral, .true, .false, .nil, .null:
            return true
        case .leftAngle, .leftBracket, .leftBrace, .leftParen:
            return true
        case .hyphen, .minus, .not:
            return true
        case .stringSegment, .interpolationStart:
            return true
        default:
            return false
        }
    }

    /// Check if current position is article followed by angle bracket (standard object syntax)
    private func isArticleFollowedByAngle() -> Bool {
        if case .article = peek().kind {
            // Look ahead to see if it's followed by <
            let nextIndex = current + 1
            if nextIndex < tokens.count && tokens[nextIndex].kind == .leftAngle {
                return true
            }
        }
        return false
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

    /// Parses: "<Require>" [article] "<" variable ">" "from" [article] "<" source ">" "."
    private func parseRequireStatement(startToken: Token) throws -> RequireStatement {
        advance() // consume 'Require'
        try expect(.rightAngle, message: "'>'")

        // Skip optional article before variable
        if case .article = peek().kind {
            advance()
        }

        try expect(.leftAngle, message: "'<'")
        let variableName = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        // Expect 'from' preposition
        guard case .preposition(.from) = peek().kind else {
            throw ParserError.unexpectedToken(expected: "'from'", got: peek())
        }
        advance()

        // Skip optional article before source
        if case .article = peek().kind {
            advance()
        }

        try expect(.leftAngle, message: "'<'")
        let sourceName = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        let endToken = try expect(.dot, message: "'.'")

        // Determine source type
        let source: RequireSource
        switch sourceName.lowercased() {
        case "framework":
            source = .framework
        case "environment":
            source = .environment
        default:
            source = .featureSet(sourceName)
        }

        return RequireStatement(
            variableName: variableName,
            source: source,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    // MARK: - Match Statement Parsing (ARO-0004)

    /// Parses: "match" "<" subject ">" "{" { case_clause } [ otherwise_clause ] "}"
    private func parseMatchStatement() throws -> MatchStatement {
        let startToken = try expect(.match, message: "'match'")

        // Parse subject: <variable>
        try expect(.leftAngle, message: "'<'")
        let subject = try parseQualifiedNoun()
        try expect(.rightAngle, message: "'>'")

        try expect(.leftBrace, message: "'{'")

        // Parse case clauses
        var cases: [CaseClause] = []
        var otherwise: [Statement]?

        while !check(.rightBrace) && !isAtEnd {
            if check(.case) {
                cases.append(try parseCaseClause())
            } else if check(.otherwise) {
                otherwise = try parseOtherwiseClause()
                // otherwise must be last
                break
            } else {
                throw ParserError.unexpectedToken(expected: "'case' or 'otherwise'", got: peek())
            }
        }

        let endToken = try expect(.rightBrace, message: "'}'")

        return MatchStatement(
            subject: subject,
            cases: cases,
            otherwise: otherwise,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Parses: "case" pattern [ "where" condition ] "{" { statement } "}"
    private func parseCaseClause() throws -> CaseClause {
        let startToken = try expect(.case, message: "'case'")

        // Parse pattern
        let pattern = try parsePattern()

        // Parse optional guard condition: where <condition>
        var guardCondition: (any Expression)?
        if check(.where) {
            advance()
            guardCondition = try parseExpression()
        }

        try expect(.leftBrace, message: "'{'")

        // Parse body statements
        var body: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            body.append(try parseStatement())
        }

        let endToken = try expect(.rightBrace, message: "'}'")

        return CaseClause(
            pattern: pattern,
            guardCondition: guardCondition,
            body: body,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Parses: "otherwise" "{" { statement } "}"
    private func parseOtherwiseClause() throws -> [Statement] {
        try expect(.otherwise, message: "'otherwise'")
        try expect(.leftBrace, message: "'{'")

        var statements: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            statements.append(try parseStatement())
        }

        try expect(.rightBrace, message: "'}'")
        return statements
    }

    /// Parses a pattern: literal | <variable> | _
    private func parsePattern() throws -> Pattern {
        // Check for wildcard
        if case .identifier("_") = peek().kind {
            advance()
            return .wildcard
        }

        // Check for literal
        if isLiteralToken(peek()) {
            let literal = try parseLiteralValue()
            return .literal(literal)
        }

        // Check for variable reference
        if check(.leftAngle) {
            advance()
            let noun = try parseQualifiedNoun()
            try expect(.rightAngle, message: "'>'")
            return .variable(noun)
        }

        throw ParserError.unexpectedToken(expected: "pattern (literal, <variable>, or _)", got: peek())
    }

    // MARK: - For-Each Loop Parsing (ARO-0005)

    /// Parses: "parallel" "for" "each" ...
    private func parseParallelForEachLoop() throws -> ForEachLoop {
        try expect(.parallel, message: "'parallel'")
        return try parseForEachLoop(isParallel: true)
    }

    /// Parses: "for" "each" "<" item ">" ["at" "<" index ">"] "in" "<" collection ">" ["with" "<" "concurrency" ":" N ">"] ["where" condition] "{" statements "}"
    private func parseForEachLoop(isParallel: Bool) throws -> ForEachLoop {
        let startToken = try expect(.for, message: "'for'")
        try expect(.each, message: "'each'")

        // Parse item variable: <item>
        try expect(.leftAngle, message: "'<'")
        let itemVariable = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        // Parse optional index: at <index>
        var indexVariable: String? = nil
        if check(.atKeyword) {
            advance()
            try expect(.leftAngle, message: "'<'")
            indexVariable = try parseCompoundIdentifier()
            try expect(.rightAngle, message: "'>'")
        }

        // Parse collection: in <collection>
        try expect(.in, message: "'in'")
        try expect(.leftAngle, message: "'<'")
        let collection = try parseQualifiedNoun()
        try expect(.rightAngle, message: "'>'")

        // Parse optional concurrency limit (only for parallel): with <concurrency: N>
        var concurrency: Int? = nil
        if isParallel && check(.preposition(.with)) {
            advance()
            try expect(.leftAngle, message: "'<'")
            try expect(.concurrency, message: "'concurrency'")
            try expect(.colon, message: "':'")
            let concurrencyToken = peek()
            if case .intLiteral(let n) = concurrencyToken.kind {
                advance()
                concurrency = n
            } else {
                throw ParserError.unexpectedToken(expected: "integer for concurrency", got: concurrencyToken)
            }
            try expect(.rightAngle, message: "'>'")
        }

        // Parse optional filter: where <condition>
        var filter: (any Expression)? = nil
        if check(.where) {
            advance()
            filter = try parseExpression()
        }

        // Parse body: { statements }
        try expect(.leftBrace, message: "'{'")
        var body: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            body.append(try parseStatement())
        }
        let endToken = try expect(.rightBrace, message: "'}'")

        return ForEachLoop(
            itemVariable: itemVariable,
            indexVariable: indexVariable,
            collection: collection,
            filter: filter,
            isParallel: isParallel,
            concurrency: concurrency,
            body: body,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    // MARK: - Qualified Noun Parsing

    /// Parses: base [ ":" type_annotation ]
    /// Type annotation can be:
    /// - Primitive: String, Integer, Float, Boolean
    /// - Collection: List<T>, Map<K, V>
    /// - OpenAPI schema: User, Order, etc.
    private func parseQualifiedNoun() throws -> QualifiedNoun {
        let startToken = peek()
        let base = try parseCompoundIdentifier()
        var typeAnnotation: String? = nil

        if check(.colon) {
            advance()

            // Parse type annotation (ARO-0006)
            typeAnnotation = try parseTypeAnnotation()
        }

        return QualifiedNoun(
            base: base,
            typeAnnotation: typeAnnotation,
            span: startToken.span.merged(with: previous().span)
        )
    }

    /// Parses a type annotation: String | Integer | Float | Boolean | List<T> | Map<K,V> | SchemaName
    /// Note: This function does NOT consume the closing `>` of the enclosing variable reference.
    /// It only consumes `<` and `>` for generic type parameters like `List<User>`.
    /// Type names can be hyphenated like "password-hash" for legacy compatibility.
    private func parseTypeAnnotation() throws -> String {
        // Parse compound identifier (may contain hyphens like "password-hash")
        var typeStr = try parseCompoundIdentifier()

        // Check for generic type parameters (List<T>, Map<K,V>)
        // Only look for `<` immediately after the type name (no whitespace)
        if check(.leftAngle) || check(.lessThan) {
            advance()
            typeStr += "<"

            // Parse first type parameter
            typeStr += try parseTypeAnnotation()

            // Check for second type parameter (for Map<K, V>)
            if check(.comma) {
                advance()
                typeStr += ", "
                typeStr += try parseTypeAnnotation()
            }

            // Expect closing angle bracket for the generic (not the outer variable)
            if check(.rightAngle) || check(.greaterThan) {
                advance()
                typeStr += ">"
            } else {
                throw ParserError.unexpectedToken(
                    expected: "'>'",
                    got: peek()
                )
            }
        } else {
            // Legacy support: parse additional space-separated specifiers
            // e.g., <user: id name> where "id" and "name" are both specifiers
            while peek().kind.isIdentifier {
                typeStr += " "
                typeStr += try parseCompoundIdentifier()
            }
        }

        return typeStr
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
        guard current < tokens.count else {
            return tokens[tokens.count - 1] // Return EOF
        }
        return tokens[current]
    }

    private func previous() -> Token {
        guard current > 0 else {
            return tokens[0]
        }
        return tokens[current - 1]
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
        // ARO-0015: Accept keywords that are also test action verbs
        // This allows <When>, <Then>, <Given>, <Assert> as action verbs
        switch token.kind {
        case .when, .then:
            return advance()
        default:
            break
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

// MARK: - Expression Parsing (ARO-0002)

/// Operator precedence levels for Pratt parsing
private enum Precedence: Int, Comparable {
    case none = 0
    case or = 1           // or
    case and = 2          // and
    case equality = 3     // == != is is_not
    case comparison = 4   // < > <= >=
    case term = 5         // + - ++
    case factor = 6       // * / %
    case unary = 7        // - not
    case postfix = 8      // . []

    static func < (lhs: Precedence, rhs: Precedence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Parser {
    // MARK: - Expression Entry Point

    /// Parses a full expression
    public func parseExpression() throws -> any Expression {
        try parsePrecedence(.none)
    }

    /// Pratt parser core - parses expressions at or above the given precedence
    private func parsePrecedence(_ minPrecedence: Precedence) throws -> any Expression {
        // Parse prefix (primary or unary)
        var left = try parsePrefix()

        // Parse infix operators at or above minPrecedence
        while let prec = infixPrecedence(peek()), prec > minPrecedence {
            left = try parseInfix(left: left, precedence: prec)
        }

        // Handle postfix existence check: <expr> exists
        if check(.exists) {
            advance()
            let span = (left as? any Locatable)?.span ?? SourceSpan.unknown
            left = ExistenceExpression(expression: left, span: span)
        }

        return left
    }

    // MARK: - Prefix Parsing

    /// Parses prefix expressions (literals, unary, grouping, variable refs, collections)
    private func parsePrefix() throws -> any Expression {
        let token = peek()

        switch token.kind {
        // Literals
        case .stringLiteral(let s):
            advance()
            return LiteralExpression(value: .string(s), span: token.span)

        case .intLiteral(let i):
            advance()
            return LiteralExpression(value: .integer(i), span: token.span)

        case .floatLiteral(let f):
            advance()
            return LiteralExpression(value: .float(f), span: token.span)

        case .true:
            advance()
            return LiteralExpression(value: .boolean(true), span: token.span)

        case .false:
            advance()
            return LiteralExpression(value: .boolean(false), span: token.span)

        case .nil, .null:
            advance()
            return LiteralExpression(value: .null, span: token.span)

        // Variable reference: <name>
        case .leftAngle:
            return try parseVariableRefExpression()

        // Array literal: [...]
        case .leftBracket:
            return try parseArrayLiteral()

        // Map literal: {...}
        case .leftBrace:
            return try parseMapLiteral()

        // Grouped expression: (...)
        case .leftParen:
            return try parseGroupedExpression()

        // Unary minus: -expr
        case .hyphen, .minus:
            advance()
            let operand = try parsePrecedence(.unary)
            let span = token.span.merged(with: (operand as? any Locatable)?.span ?? token.span)
            return UnaryExpression(op: .negate, operand: operand, span: span)

        // Unary not: not expr
        case .not:
            advance()
            let operand = try parsePrecedence(.unary)
            let span = token.span.merged(with: (operand as? any Locatable)?.span ?? token.span)
            return UnaryExpression(op: .not, operand: operand, span: span)

        // String interpolation tokens
        case .stringSegment(let s):
            return try parseInterpolatedString(firstSegment: s, startSpan: token.span)

        case .interpolationStart:
            return try parseInterpolatedString(firstSegment: nil, startSpan: token.span)

        default:
            throw ParserError.unexpectedToken(expected: "expression", got: token)
        }
    }

    // MARK: - Infix Parsing

    /// Gets the precedence of an infix operator
    private func infixPrecedence(_ token: Token) -> Precedence? {
        switch token.kind {
        case .or: return .or
        case .and: return .and
        case .equalEqual, .bangEqual, .is, .contains, .matches: return .equality
        case .lessThan, .greaterThan, .lessEqual, .greaterEqual: return .comparison
        // Handle < and > as comparison operators in expression context
        // They will only reach here if not part of a <variable> reference
        case .leftAngle, .rightAngle:
            // Only treat as comparison if not followed by identifier (which would start a variable ref)
            let nextIndex = current + 1
            if nextIndex < tokens.count {
                if case .identifier = tokens[nextIndex].kind {
                    // This could be starting a variable ref, don't treat as comparison
                    return nil
                }
            }
            return .comparison
        case .plus, .minus, .plusPlus: return .term
        case .star, .slash, .percent: return .factor
        case .leftBracket: return .postfix
        case .dot:
            // Only treat . as member access if followed by identifier
            // This prevents statement-ending . from being parsed as member access
            let nextIndex = current + 1
            if nextIndex < tokens.count {
                if case .identifier = tokens[nextIndex].kind {
                    return .postfix
                }
            }
            return nil
        default: return nil
        }
    }

    /// Parses infix expressions (binary operators, member access)
    private func parseInfix(left: any Expression, precedence: Precedence) throws -> any Expression {
        let token = peek()

        switch token.kind {
        // Member access: .name
        case .dot:
            advance()
            let memberToken = try expectIdentifier(message: "member name")
            let span = (left as? any Locatable)?.span.merged(with: memberToken.span) ?? memberToken.span
            return MemberAccessExpression(base: left, member: memberToken.lexeme, span: span)

        // Subscript: [index]
        case .leftBracket:
            advance()
            let index = try parseExpression()
            let endToken = try expect(.rightBracket, message: "']'")
            let span = (left as? any Locatable)?.span.merged(with: endToken.span) ?? endToken.span
            return SubscriptExpression(base: left, index: index, span: span)

        // Binary operators
        default:
            advance()
            guard let op = binaryOperator(from: token.kind) else {
                throw ParserError.unexpectedToken(expected: "binary operator", got: token)
            }

            // Handle "is not" as two tokens
            var actualOp = op
            if op == .is && check(.not) {
                advance()
                actualOp = .isNot
            }

            // Handle "is true", "is false", "is nil/null" as equality comparisons
            if actualOp == .is || actualOp == .isNot {
                // Check if next token is a boolean literal or nil
                switch peek().kind {
                case .true, .false, .nil, .null:
                    // Treat as equality comparison: <expr> == true/false/nil
                    let right = try parsePrefix()
                    let span = (left as? any Locatable)?.span.merged(with: (right as? any Locatable)?.span ?? token.span) ?? token.span
                    let compOp: BinaryOperator = (actualOp == .isNot) ? .notEqual : .equal
                    return BinaryExpression(left: left, op: compOp, right: right, span: span)
                default:
                    break
                }

                // Handle type check: <expr> is [a/an] TypeName
                // Skip optional article
                var hasArticle = false
                if case .article = peek().kind {
                    advance()
                    hasArticle = true
                }

                // Parse type name
                let typeToken = try expectIdentifier(message: "type name")
                let span = (left as? any Locatable)?.span.merged(with: typeToken.span) ?? typeToken.span

                if actualOp == .isNot {
                    // "is not" followed by type is a negated type check
                    let typeCheck = TypeCheckExpression(expression: left, typeName: typeToken.lexeme, hasArticle: hasArticle, span: span)
                    return UnaryExpression(op: .not, operand: typeCheck, span: span)
                }

                return TypeCheckExpression(expression: left, typeName: typeToken.lexeme, hasArticle: hasArticle, span: span)
            }

            // Parse right operand with higher precedence (left-associative)
            let right = try parsePrecedence(precedence)
            let span = (left as? any Locatable)?.span.merged(with: (right as? any Locatable)?.span ?? token.span) ?? token.span

            return BinaryExpression(left: left, op: actualOp, right: right, span: span)
        }
    }

    /// Maps token kind to binary operator
    private func binaryOperator(from kind: TokenKind) -> BinaryOperator? {
        switch kind {
        case .plus: return .add
        case .minus: return .subtract
        case .star: return .multiply
        case .slash: return .divide
        case .percent: return .modulo
        case .plusPlus: return .concat
        case .equalEqual: return .equal
        case .bangEqual: return .notEqual
        case .lessThan, .leftAngle: return .lessThan
        case .greaterThan, .rightAngle: return .greaterThan
        case .lessEqual: return .lessEqual
        case .greaterEqual: return .greaterEqual
        case .is: return .is
        case .and: return .and
        case .or: return .or
        case .contains: return .contains
        case .matches: return .matches
        default: return nil
        }
    }

    // MARK: - Specific Expression Parsers

    /// Parses a variable reference: <name> or <name: specifier>
    private func parseVariableRefExpression() throws -> VariableRefExpression {
        let startToken = try expect(.leftAngle, message: "'<'")
        let noun = try parseQualifiedNoun()
        let endToken = try expect(.rightAngle, message: "'>'")
        return VariableRefExpression(noun: noun, span: startToken.span.merged(with: endToken.span))
    }

    /// Parses an array literal: [elem1, elem2, ...]
    private func parseArrayLiteral() throws -> ArrayLiteralExpression {
        let startToken = try expect(.leftBracket, message: "'['")
        var elements: [any Expression] = []

        if !check(.rightBracket) {
            elements.append(try parseExpression())
            while check(.comma) {
                advance()
                if check(.rightBracket) { break } // Allow trailing comma
                elements.append(try parseExpression())
            }
        }

        let endToken = try expect(.rightBracket, message: "']'")
        return ArrayLiteralExpression(elements: elements, span: startToken.span.merged(with: endToken.span))
    }

    /// Parses a map literal: { key: value, ... }
    private func parseMapLiteral() throws -> MapLiteralExpression {
        let startToken = try expect(.leftBrace, message: "'{'")
        var entries: [MapEntry] = []

        if !check(.rightBrace) {
            entries.append(try parseMapEntry())
            while check(.comma) {
                advance()
                if check(.rightBrace) { break } // Allow trailing comma
                entries.append(try parseMapEntry())
            }
        }

        let endToken = try expect(.rightBrace, message: "'}'")
        return MapLiteralExpression(entries: entries, span: startToken.span.merged(with: endToken.span))
    }

    /// Parses a single map entry: key: value
    private func parseMapEntry() throws -> MapEntry {
        let keyToken = peek()
        let key: String

        // Key can be identifier or string literal
        switch keyToken.kind {
        case .identifier(let s):
            advance()
            key = s
        case .stringLiteral(let s):
            advance()
            key = s
        default:
            // Also accept compound identifiers
            key = try parseCompoundIdentifier()
        }

        try expect(.colon, message: "':'")
        let value = try parseExpression()

        return MapEntry(key: key, value: value, span: keyToken.span.merged(with: (value as? any Locatable)?.span ?? keyToken.span))
    }

    /// Parses a grouped (parenthesized) expression: (expr)
    private func parseGroupedExpression() throws -> GroupedExpression {
        let startToken = try expect(.leftParen, message: "'('")
        let expr = try parseExpression()
        let endToken = try expect(.rightParen, message: "')'")
        return GroupedExpression(expression: expr, span: startToken.span.merged(with: endToken.span))
    }

    /// Parses an interpolated string from its tokens
    private func parseInterpolatedString(firstSegment: String?, startSpan: SourceSpan) throws -> InterpolatedStringExpression {
        var parts: [StringPart] = []

        // Add first segment if provided
        if let seg = firstSegment {
            advance() // consume the stringSegment token
            parts.append(.literal(seg))
        }

        // Parse remaining segments and interpolations
        while !isAtEnd {
            switch peek().kind {
            case .stringSegment(let s):
                advance()
                parts.append(.literal(s))

            case .interpolationStart:
                advance()
                // The next token should be the expression content as a stringSegment
                // We need to re-lex and parse this content
                if case .stringSegment(let exprStr) = peek().kind {
                    advance()
                    // Parse the expression string
                    let exprTokens = try Lexer.tokenize(exprStr)
                    let exprParser = Parser(tokens: exprTokens, diagnostics: diagnostics)
                    let expr = try exprParser.parseExpression()
                    parts.append(.interpolation(expr))
                }
                // Consume interpolationEnd
                if check(.interpolationEnd) {
                    advance()
                }

            case .interpolationEnd:
                advance()

            default:
                // End of interpolated string
                break
            }

            // Break if we're not seeing more string parts
            if case .stringSegment = peek().kind { continue }
            if case .interpolationStart = peek().kind { continue }
            break
        }

        return InterpolatedStringExpression(parts: parts, span: startSpan.merged(with: previous().span))
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
