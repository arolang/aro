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

        // Parse optional when clause for feature set guards (e.g., Observer when condition)
        var whenCondition: (any Expression)? = nil
        if check(.when) {
            advance() // consume 'when'
            whenCondition = try parseExpression()
        }

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
            whenCondition: whenCondition,
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

        // Check for Publish/Require special forms (no angle brackets, like other actions)
        if check(.publish) {
            let startToken = advance()
            return try parsePublishStatement(startToken: startToken)
        }
        if check(.require) {
            let startToken = advance()
            return try parseRequireStatement(startToken: startToken)
        }

        // Parse ARO statement (action without angle brackets)
        return try parseAROStatement()
    }
    
    /// Parses: Action [article] "<" result ">" preposition [article] "<" object ">" ["when" condition] "."
    /// ARO-0002: Also supports expressions after prepositions like `from <x> * <y>` or `to 30`
    /// ARO-0004: Also supports guarded statements with `when` clause
    /// ARO-0043: Also supports sink syntax like `Log "message" to the <console>.`
    private func parseAROStatement() throws -> AROStatement {
        // Parse action verb (capitalized identifier or testing keyword)
        let startToken = peek()
        let actionToken: Token
        let action: Action

        // Check for testing keywords (when, then, assert) which are lexed as keywords
        // Note: 'Given' is NOT a keyword - it's parsed as an identifier
        switch peek().kind {
        case .when, .then, .assert:
            actionToken = advance()
            // Capitalize the keyword for consistency (when -> When, then -> Then, etc.)
            let capitalizedVerb = actionToken.lexeme.prefix(1).uppercased() + actionToken.lexeme.dropFirst()
            action = Action(verb: capitalizedVerb, span: actionToken.span)
        case .identifier(let verb) where verb.first?.isUppercase == true:
            actionToken = advance()
            action = Action(verb: actionToken.lexeme, span: actionToken.span)
        default:
            throw ParserError.unexpectedToken(expected: "action verb (e.g., Extract, Filter, Return)", got: peek())
        }

        // ARO-0043: Check for sink verb syntax
        // Sink verbs: log, print, output, debug, write, send, dispatch
        // Syntax: <Log> "message" to the <console>.
        //         <Write> <data> to the <file: "./output.json">.
        let isSinkVerb = isSinkActionVerb(action.verb)
        var resultExpression: (any Expression)? = nil

        // Check if we should parse sink syntax:
        // After a sink verb, if we see an expression-starting token (like string literal)
        // OR a `<variable>` NOT preceded by an article, treat it as sink syntax
        let useSinkSyntax = isSinkVerb && isSinkSyntaxStart(peek())

        var result: QualifiedNoun
        if useSinkSyntax {
            // ARO-0043: Parse expression as the value to output
            resultExpression = try parseExpression()
            // Create a placeholder result noun
            result = QualifiedNoun(base: "_sink_", specifiers: [], span: previous().span)
        } else {
            // Standard syntax: [article] <result>
            // Skip optional article before result
            if case .article = peek().kind {
                advance()
            }

            // Parse result
            try expect(.leftAngle, message: "'<'")
            result = try parseQualifiedNoun()
            try expect(.rightAngle, message: "'>'")

            // ARO-0038: Check for optional 'as Type' annotation after result
            // Syntax: <result> as Type  (alternative to <result: Type>)
            if check(.as) {
                advance()
                let typeAnnotation = try parseTypeAnnotation()
                result = QualifiedNoun(
                    base: result.base,
                    typeAnnotation: typeAnnotation,
                    span: result.span
                )
            }
        }

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
        let literalValue: LiteralValue? = nil
        var expression: (any Expression)? = nil
        var aggregation: AggregationClause? = nil
        var toExpression: (any Expression)? = nil

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
        }

        // Parse optional with clause: `with "string"` or `with <expr>` or `with sum(<field>)`
        // This is placed outside the if/else to handle both expression and standard object syntax (ARO-0042)
        var withExpression: (any Expression)? = nil
        if case .preposition(.with) = peek().kind {
            advance() // consume 'with'
            // Check for aggregation functions: sum(<field>), count(), avg(<field>)
            if let agg = try parseAggregationIfPresent() {
                aggregation = agg
            } else if isExpressionStart(peek()) {
                // If we're in expression mode (object is an expression like `from <variable>`),
                // store the with clause separately for set operations (ARO-0042).
                // Otherwise, use the standard expression binding for existing actions.
                if objectNoun.base == "_expression_" {
                    // Expression mode: `from <a> with <b>` - store in withClause for set operations
                    withExpression = try parseExpression()
                } else {
                    // Standard mode: `from the <object> with <expr>` - use regular expression binding
                    expression = try parseExpression()
                }
            }
        }

        // Parse optional to clause (ARO-0041): `from <start> to <end>` for date ranges
        // This is placed outside the if/else to handle both expression and standard object syntax
        if case .preposition(let p) = peek().kind, p == .to {
            advance() // consume 'to'
            toExpression = try parseExpression()
        }

        // Parse optional where clause (ARO-0018): `where <field> is "value"` or `where <field> > 1000`
        var whereClause: WhereClause?
        if check(.where) {
            advance() // consume 'where'
            whereClause = try parseWhereClause()
        }

        // Parse optional by clause (ARO-0037): `by /pattern/flags`
        var byClause: ByClause?
        if case .preposition(.by) = peek().kind {
            let byToken = advance() // consume 'by'
            if case .regexLiteral(let pattern, let flags) = peek().kind {
                advance() // consume regex literal
                byClause = ByClause(pattern: pattern, flags: flags, span: byToken.span.merged(with: previous().span))
            } else {
                throw ParserError.unexpectedToken(expected: "regex literal after 'by'", got: peek())
            }
        }

        // Parse optional when clause (ARO-0004): `when <condition>`
        var whenCondition: (any Expression)?
        if check(.when) {
            advance() // consume 'when'
            whenCondition = try parseExpression()
        }

        let endToken = try expect(.dot, message: "'.'")

        // Build grouped types from parsed fields
        let valueSource: ValueSource
        if let resExpr = resultExpression {
            valueSource = .sinkExpression(resExpr)
        } else if let expr = expression {
            valueSource = .expression(expr)
        } else if let literal = literalValue {
            valueSource = .literal(literal)
        } else {
            valueSource = .none
        }

        let queryMods = QueryModifiers(
            whereClause: whereClause,
            aggregation: aggregation,
            byClause: byClause
        )

        let rangeMods = RangeModifiers(
            toClause: toExpression,
            withClause: withExpression
        )

        let guard_ = StatementGuard(condition: whenCondition)

        return AROStatement(
            action: action,
            result: result,
            object: ObjectClause(preposition: prep, noun: objectNoun),
            valueSource: valueSource,
            queryModifiers: queryMods,
            rangeModifiers: rangeMods,
            statementGuard: guard_,
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

    // MARK: - Sink Syntax Helpers (ARO-0043)

    /// Check if a verb is a sink action verb
    /// Sink verbs write data TO system objects
    private func isSinkActionVerb(_ verb: String) -> Bool {
        let sinkVerbs: Set<String> = [
            "log", "print", "output", "debug",  // LogAction
            "write",                             // WriteAction
            "send", "dispatch"                   // SendAction
        ]
        return sinkVerbs.contains(verb.lowercased())
    }

    /// Check if the current token starts sink syntax
    /// Sink syntax: <Log> "message" or <Log> <data> (without preceding article)
    private func isSinkSyntaxStart(_ token: Token) -> Bool {
        // Sink syntax starts with:
        // 1. String literal: <Log> "message"
        // 2. Numeric literal: <Log> 42
        // 3. Object/array literal: <Log> { key: value } or <Log> [1, 2, 3]
        // 4. Variable reference (without article): <Log> <data>
        //    Note: Standard syntax has article: <Log> the <result>
        switch token.kind {
        case .stringLiteral, .intLiteral, .floatLiteral:
            return true
        case .leftBrace, .leftBracket:
            return true
        case .leftAngle:
            // <variable> without preceding article indicates sink syntax
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
        case .stringLiteral, .intLiteral, .floatLiteral, .regexLiteral, .true, .false, .nil, .null:
            return true
        default:
            return false
        }
    }

    /// Parses aggregation function if present: sum(<field>), count(), avg(<field>), min(<field>), max(<field>)
    /// Returns nil if not an aggregation function
    private func parseAggregationIfPresent() throws -> AggregationClause? {
        // Check for aggregation function name
        guard case .identifier(let name) = peek().kind else {
            return nil
        }

        // Map identifier to aggregation type
        let aggType: AggregationType?
        switch name.lowercased() {
        case "sum": aggType = .sum
        case "count": aggType = .count
        case "avg": aggType = .avg
        case "min": aggType = .min
        case "max": aggType = .max
        default: aggType = nil
        }

        guard let type = aggType else {
            return nil
        }

        let startSpan = peek().span
        advance() // consume function name

        // Expect (
        try expect(.leftParen, message: "'('")

        // Parse optional field: <field> or empty for count()
        var field: String? = nil
        if check(.leftAngle) {
            advance() // consume <
            field = try parseCompoundIdentifier()
            try expect(.rightAngle, message: "'>'")
        }

        let endSpan = try expect(.rightParen, message: "')'").span

        return AggregationClause(type: type, field: field, span: startSpan.merged(with: endSpan))
    }

    /// Parses where clause: <field> is "value" or <field> > 1000
    private func parseWhereClause() throws -> WhereClause {
        let startSpan = peek().span

        // Parse field: <field>
        try expect(.leftAngle, message: "'<'")
        let field = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        // Parse operator
        let op: WhereOperator
        switch peek().kind {
        case .is:
            advance()
            // Check for "is not"
            if check(.not) {
                advance()
                op = .notEqual
            } else {
                op = .equal
            }
        case .lessThan, .leftAngle:
            advance()
            if check(.equals) {
                advance()
                op = .lessEqual
            } else {
                op = .lessThan
            }
        case .greaterThan, .rightAngle:
            advance()
            if check(.equals) {
                advance()
                op = .greaterEqual
            } else {
                op = .greaterThan
            }
        case .equalEqual, .equals:
            advance()
            op = .equal
        case .bangEqual:
            advance()
            op = .notEqual
        case .contains:
            advance()
            op = .contains
        case .matches:
            advance()
            op = .matches
        case .in:
            advance()
            op = .in
        case .not:
            advance()
            // Must be followed by 'in' for "not in"
            if check(.in) {
                advance()
                op = .notIn
            } else {
                throw ParserError.unexpectedToken(expected: "'in' after 'not' in where clause", got: peek())
            }
        default:
            throw ParserError.unexpectedToken(expected: "comparison operator (is, =, <, >, <=, >=, !=, contains, matches, in, not in)", got: peek())
        }

        // Parse value expression
        let value = try parseExpression()

        return WhereClause(field: field, op: op, value: value, span: startSpan.merged(with: value.span))
    }

    /// Parses a literal value (string, number, boolean, null, regex)
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
        case .regexLiteral(let pattern, let flags):
            advance()
            return .regex(pattern: pattern, flags: flags)
        case .true:
            advance()
            return .boolean(true)
        case .false:
            advance()
            return .boolean(false)
        case .nil, .null:
            advance()
            return .null
        case .leftBracket:
            return try parseArrayLiteral()
        case .leftBrace:
            return try parseObjectLiteral()
        default:
            throw ParserError.unexpectedToken(expected: "literal value", got: token)
        }
    }

    /// Parses: "[" [ literal { "," literal } ] "]"
    private func parseArrayLiteral() throws -> LiteralValue {
        try expect(.leftBracket, message: "'['")
        var elements: [LiteralValue] = []

        // Handle empty array
        if check(.rightBracket) {
            advance()
            return .array(elements)
        }

        // Parse first element
        elements.append(try parseLiteralValue())

        // Parse remaining elements
        while check(.comma) {
            advance() // consume comma
            // Allow trailing comma before ]
            if check(.rightBracket) {
                break
            }
            elements.append(try parseLiteralValue())
        }

        try expect(.rightBracket, message: "']'")
        return .array(elements)
    }

    /// Parses: "{" [ key ":" value { "," key ":" value } ] "}"
    /// Key can be identifier or hyphenated-identifier
    private func parseObjectLiteral() throws -> LiteralValue {
        try expect(.leftBrace, message: "'{'")
        var fields: [(String, LiteralValue)] = []

        // Handle empty object
        if check(.rightBrace) {
            advance()
            return .object(fields)
        }

        // Parse first field
        let (key, value) = try parseObjectField()
        fields.append((key, value))

        // Parse remaining fields
        while check(.comma) {
            advance() // consume comma
            // Allow trailing comma before }
            if check(.rightBrace) {
                break
            }
            let (k, v) = try parseObjectField()
            fields.append((k, v))
        }

        try expect(.rightBrace, message: "'}'")
        return .object(fields)
    }

    /// Parses: key ":" value
    /// Key can be: identifier, identifier-identifier-..., or string literal
    private func parseObjectField() throws -> (String, LiteralValue) {
        // Parse key (supports hyphenated identifiers like "customer-name")
        var key = ""
        if case .stringLiteral(let s) = peek().kind {
            advance()
            key = s
        } else if case .identifier(let name) = peek().kind {
            advance()
            key = name
            // Handle hyphenated keys: customer-name, order-id, etc.
            while check(.hyphen) {
                advance() // consume hyphen
                key += "-"
                if case .identifier(let nextPart) = peek().kind {
                    advance()
                    key += nextPart
                } else {
                    throw ParserError.unexpectedToken(expected: "identifier after hyphen", got: peek())
                }
            }
        } else {
            throw ParserError.unexpectedToken(expected: "field name", got: peek())
        }

        try expect(.colon, message: "':'")
        let value = try parseLiteralValue()
        return (key, value)
    }
    
    /// Parses: "Publish" "as" "<" external ">" "<" internal ">" "."
    private func parsePublishStatement(startToken: Token) throws -> PublishStatement {
        // 'Publish' already consumed in parseStatement()

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

    /// Parses: "Require" [article] "<" variable ">" "from" [article] "<" source ">" "."
    private func parseRequireStatement(startToken: Token) throws -> RequireStatement {
        // 'Require' already consumed in parseStatement()

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

    /// Parses a pattern: literal | <variable> | _ | /regex/flags
    private func parsePattern() throws -> Pattern {
        // Check for wildcard
        if case .identifier("_") = peek().kind {
            advance()
            return .wildcard
        }

        // Check for regex literal
        if case .regexLiteral(let pattern, let flags) = peek().kind {
            advance()
            return .regex(pattern: pattern, flags: flags)
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

        throw ParserError.unexpectedToken(expected: "pattern (literal, <variable>, _, or /regex/)", got: peek())
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

            // ARO-0068: Check for string literal after colon (e.g., <command: "uptime">)
            // This allows commands and other values to be specified inline
            if case .stringLiteral(let value) = peek().kind {
                advance()
                typeAnnotation = value
            } else {
                // Parse type annotation (ARO-0006)
                typeAnnotation = try parseTypeAnnotation()
            }
        }

        return QualifiedNoun(
            base: base,
            typeAnnotation: typeAnnotation,
            span: startToken.span.merged(with: previous().span)
        )
    }

    /// Parses a type annotation: String | Integer | Float | Boolean | List<T> | Map<K,V> | SchemaName | DateOffset
    /// Note: This function does NOT consume the closing `>` of the enclosing variable reference.
    /// It only consumes `<` and `>` for generic type parameters like `List<User>`.
    /// Type names can be hyphenated like "password-hash" for legacy compatibility.
    /// Date offsets like "+7d", "-3h" are also supported (ARO-0041).
    private func parseTypeAnnotation() throws -> String {
        // Check for date offset pattern (ARO-0041): +7d, -3h, etc.
        // Also check for negative integer literals (lexer may parse "-1" as intLiteral(-1))
        if check(.plus) || check(.minus) {
            return try parseDateOffsetPattern()
        }
        if case .intLiteral(let value) = peek().kind, value < 0 {
            return try parseDateOffsetPattern()
        }

        // Check for numeric range specifier (ARO-0038): 0, 0-19, 0,3,7
        // This handles list element access patterns
        if case .intLiteral(let startValue) = peek().kind, startValue >= 0 {
            return try parseNumericSpecifier()
        }

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
            // Parse dot-separated property path or slash-separated file path
            // e.g., <user: profile.name> where "profile" and "name" form a property path
            // e.g., <template: emails/welcome.tpl> where "emails/welcome.tpl" is a file path
            while check(.dot) || check(.slash) {
                // Peek ahead to distinguish member access from statement-ending dot
                let nextIdx = current + 1
                if nextIdx < tokens.count, tokens[nextIdx].kind.isIdentifier {
                    let separator = peek()
                    advance() // consume dot or slash
                    if case .dot = separator.kind {
                        typeStr += "."
                    } else {
                        typeStr += "/"
                    }
                    typeStr += try parseCompoundIdentifier()
                } else {
                    break
                }
            }
        }

        return typeStr
    }

    /// Parses a date offset pattern like +7d, -3h, +2w (ARO-0041)
    /// Format: ("+" | "-") number unit
    /// Units: s, m, h, d, w, M, y (or full names like seconds, minutes, hours, days, weeks, months, years)
    private func parseDateOffsetPattern() throws -> String {
        var result = ""

        // Check if the number is already signed (lexer may produce intLiteral(-1) for "-1")
        if case .intLiteral(let signedValue) = peek().kind, signedValue < 0 {
            // Negative number already includes the sign
            advance()
            result = String(signedValue)
        } else {
            // Consume explicit sign (+ or -)
            if check(.plus) {
                advance()
                result += "+"
            } else if check(.minus) {
                advance()
                result += "-"
            }

            // Expect a positive number
            guard case .intLiteral(let value) = peek().kind else {
                throw ParserError.unexpectedToken(expected: "integer", got: peek())
            }
            advance()
            result += String(value)
        }

        // Expect unit identifier (s, m, h, d, w, M, y, or full name)
        let unitToken = try expectIdentifier(message: "time unit (s, m, h, d, w, M, y)")
        result += unitToken.lexeme

        return result
    }

    /// Parses a numeric specifier for list element access (ARO-0038)
    /// Formats:
    /// - Single index: "0", "5", "19"
    /// - Range: "0-19", "3-5"
    /// - Pick: "0,3,7"
    /// Note: The lexer tokenizes "0-19" as intLiteral(0) followed by intLiteral(-19),
    /// so we need to handle negative integers as range end values.
    private func parseNumericSpecifier() throws -> String {
        var result = ""

        // Parse first number
        guard case .intLiteral(let firstValue) = peek().kind else {
            throw ParserError.unexpectedToken(expected: "integer", got: peek())
        }
        advance()
        result = String(firstValue)

        // Check for range - the lexer produces intLiteral(-19) for "0-19" after the first "0"
        // So we look for a negative integer literal which indicates a range
        if case .intLiteral(let nextValue) = peek().kind, nextValue < 0 {
            advance()
            // Convert negative to range: -19 means range end is 19
            result += "-"
            result += String(abs(nextValue))
        }
        // Check for explicit hyphen (in case lexer produces it separately)
        else if check(.hyphen) {
            advance()
            result += "-"
            guard case .intLiteral(let endValue) = peek().kind else {
                throw ParserError.unexpectedToken(expected: "integer", got: peek())
            }
            advance()
            result += String(endValue)
        }
        // Check for pick (e.g., 0,3,7)
        else if check(.comma) {
            while check(.comma) {
                advance()
                result += ","
                guard case .intLiteral(let nextValue) = peek().kind else {
                    throw ParserError.unexpectedToken(expected: "integer", got: peek())
                }
                advance()
                result += String(nextValue)
            }
        }

        return result
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
    /// Also supports angle bracket suffixes for filters (e.g., "status StateObserver<draft_to_placed>")
    private func parseIdentifierSequence() throws -> String {
        var parts: [String] = []

        while peek().kind.isIdentifierLike {
            // Parse compound identifier (handles hyphens)
            var compound = advance().lexeme
            while check(.hyphen) {
                advance()
                compound += "-"
                if peek().kind.isIdentifierLike {
                    compound += advance().lexeme
                } else {
                    // Put back the hyphen conceptually by breaking
                    // (trailing hyphen without identifier is invalid)
                    break
                }
            }

            // Handle angle bracket filter suffix (e.g., StateObserver<draft_to_placed>)
            if check(.leftAngle) || check(.lessThan) {
                advance() // consume <
                compound += "<"
                // Collect everything until >
                while !check(.rightAngle) && !check(.greaterThan) && !isAtEnd {
                    compound += advance().lexeme
                }
                if check(.rightAngle) || check(.greaterThan) {
                    advance() // consume >
                    compound += ">"
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
        // Accept identifier tokens and identifier-like keywords (e.g., "error")
        if token.kind.isIdentifierLike {
            return advance()
        }
        // Also accept articles (a, an, the) as identifiers when inside <...>
        // This allows <a>, <an>, <the> as valid variable names
        if case .article = token.kind {
            return advance()
        }
        // ARO-0015: Accept keywords that are also test action verbs
        // This allows <When>, <Then>, <Given>, <Assert> as action verbs
        // ARO-0036: Accept "exists" as action verb for file existence checks
        switch token.kind {
        case .when, .then, .exists:
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
        // Always advance at least once to make progress and avoid infinite loops
        // when we're already positioned after a statement-ending dot
        if !isAtEnd {
            advance()
        }

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
            let span = left.span
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

        case .regexLiteral(let pattern, let flags):
            advance()
            return LiteralExpression(value: .regex(pattern: pattern, flags: flags), span: token.span)

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
            let span = token.span.merged(with: operand.span)
            return UnaryExpression(op: .negate, operand: operand, span: span)

        // Unary not: not expr
        case .not:
            advance()
            let operand = try parsePrecedence(.unary)
            let span = token.span.merged(with: operand.span)
            return UnaryExpression(op: .not, operand: operand, span: span)

        // String interpolation tokens
        case .stringSegment(let s):
            return try parseInterpolatedString(firstSegment: s, startSpan: token.span)

        case .interpolationStart:
            return try parseInterpolatedString(firstSegment: nil, startSpan: token.span)

        // Bare identifier (e.g., in string interpolation ${name})
        case .identifier(let name):
            advance()
            // Create a QualifiedNoun for the identifier
            let noun = QualifiedNoun(base: name, typeAnnotation: nil, span: token.span)
            return VariableRefExpression(noun: noun, span: token.span)

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
        case .plus, .minus, .hyphen, .plusPlus: return .term
        case .star, .slash, .percent: return .factor
        case .leftBracket: return .postfix
        case .dot:
            // Only treat . as member access if followed by a lowercase identifier
            // This prevents statement-ending . from being parsed as member access
            // Capitalized identifiers are action verbs (Log, Return, etc.) and start new statements
            let nextIndex = current + 1
            if nextIndex < tokens.count {
                if case .identifier(let name) = tokens[nextIndex].kind {
                    // Only treat as member access if identifier starts with lowercase
                    // Uppercase identifiers are action verbs that start new statements
                    if let first = name.first, first.isLowercase {
                        return .postfix
                    }
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
            let span = left.span.merged(with: memberToken.span)
            return MemberAccessExpression(base: left, member: memberToken.lexeme, span: span)

        // Subscript: [index]
        case .leftBracket:
            advance()
            let index = try parseExpression()
            let endToken = try expect(.rightBracket, message: "']'")
            let span = left.span.merged(with: endToken.span)
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
                    let span = left.span.merged(with: right.span)
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
                let span = left.span.merged(with: typeToken.span)

                if actualOp == .isNot {
                    // "is not" followed by type is a negated type check
                    let typeCheck = TypeCheckExpression(expression: left, typeName: typeToken.lexeme, hasArticle: hasArticle, span: span)
                    return UnaryExpression(op: .not, operand: typeCheck, span: span)
                }

                return TypeCheckExpression(expression: left, typeName: typeToken.lexeme, hasArticle: hasArticle, span: span)
            }

            // Parse right operand with higher precedence (left-associative)
            let right = try parsePrecedence(precedence)
            let span = left.span.merged(with: right.span)

            return BinaryExpression(left: left, op: actualOp, right: right, span: span)
        }
    }

    /// Maps token kind to binary operator
    private func binaryOperator(from kind: TokenKind) -> BinaryOperator? {
        switch kind {
        case .plus: return .add
        case .minus, .hyphen: return .subtract
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
    /// Key can be: identifier, hyphenated-identifier, or string literal
    private func parseMapEntry() throws -> MapEntry {
        let keyToken = peek()
        var key: String

        // Key can be identifier or string literal
        switch keyToken.kind {
        case .identifier(let s):
            advance()
            key = s
            // Handle hyphenated keys: customer-name, order-id, etc.
            while check(.hyphen) {
                advance() // consume hyphen
                key += "-"
                if case .identifier(let nextPart) = peek().kind {
                    advance()
                    key += nextPart
                } else {
                    throw ParserError.unexpectedToken(expected: "identifier after hyphen", got: peek())
                }
            }
        case .stringLiteral(let s):
            advance()
            key = s
        default:
            // Also accept compound identifiers
            key = try parseCompoundIdentifier()
        }

        try expect(.colon, message: "':'")
        let value = try parseExpression()

        return MapEntry(key: key, value: value, span: keyToken.span.merged(with: value.span))
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
                // Parse the expression directly from the token stream
                // The Lexer has already tokenized the expression content
                if !check(.interpolationEnd) {
                    let expr = try parseExpression()
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
