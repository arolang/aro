// ============================================================
// Parser.swift
// ARO Parser - Recursive Descent Parser
// ============================================================
//
// Error-handling contract (#340):
//
// - The parser **throws** on the first unrecoverable syntax
//   error inside a feature set / import declaration, then
//   `synchronize()` skips to the next plausible recovery point
//   so the rest of the file can still produce diagnostics in
//   one pass.
// - Every error — thrown or recovered — is **appended to the
//   shared `DiagnosticCollector`** the caller passed in.
//   Callers inspect `diagnostics.errors` to decide whether to
//   proceed (downstream passes are run only on the
//   successfully-parsed prefix of the program).
// - `SemanticAnalyzer.analyze` is `nonthrowing` — it always
//   returns an `AnalyzedProgram` so the IDE / LSP path can show
//   partial information. Failures are recorded in the same
//   collector.
// - `DataFlowAnalyzer` follows the same nonthrowing contract:
//   missing dependencies become diagnostics, not exceptions.
//
// Net contract for the AROParser module:
//   - `try parser.parse()` produces a best-effort AST and an
//     error-collecting diagnostics bag.
//   - Subsequent analyzers never throw; they refine the
//     diagnostics in the same bag.
//   - The static convenience has two forms (GitLab #543):
//     `Parser.parse(source, diagnostics:)` recovers, as above;
//     `Parser.parse(source)` throws instead, because a caller with
//     no collector cannot otherwise tell a file that failed to
//     parse from a file with no feature sets — both are a Program
//     with zero feature sets, and reading a broken file as empty is
//     how a graph diff once reported 144 feature sets rewritten.
//
// ------------------------------------------------------------
// TokenKind dispatch map (#337)
// ------------------------------------------------------------
// The parser decides "what does this leading token start?" at
// three levels. Each level's *primary* dispatch is centralized
// and documented so adding a token/rule is one edit:
//
//   1. Statement level  — `statementDispatch` (static table).
//        Leading keyword → statement parser. Default fallthrough
//        is an ARO action statement / `|>` pipeline.
//   2. Expression prefix — `parsePrefix` (single dispatch site).
//        Leading token → prefix expression parser. Payload cases
//        (identifier/literals) bind their value inline, so this
//        stays one pattern-matching `switch` rather than a
//        closure table that would re-extract payloads.
//   3. Expression infix  — `binaryPrecedence` (static table, #348)
//        + `infixPrecedence`/`parseInfix`. Operator token →
//        precedence/parser; context-sensitive `<`,`>`,`.`,`[`
//        keep their lookahead in `infixPrecedence`.
//
// The remaining `switch`es over TokenKind are deliberately kept
// LOCAL: they are single-production decisions, not parse-rule
// selection, and a global table would obscure rather than help.
// They are, with the value they map to:
//   - `parseImportPath`        token → path fragment
//   - `parseActionVerb`        verb-shaped token → Action
//   - `isExpressionStart` / `isSinkSyntaxStart` / `isLiteralToken`
//                              token → Bool predicates
//   - `parseWherePredicate`    token → WhereOperator
//   - `parseLiteralValue`      literal token → LiteralValue
//   - `parseAggregationIfPresent` name → AggregationType
//   - `parseRequireStatement`  source name → RequireSource
//   - `expectIdentifier`       keyword-as-identifier acceptance
//   - `binaryOperator(from:)`  token → BinaryOperator
//   - `parseMapEntry`          token → map key
//   - `parseInterpolatedString` interpolation token → StringPart
// Adding a new *dispatch* (a token that starts a new kind of
// statement/expression) touches only the three tables above.

import Foundation

/// Parses tokens into an Abstract Syntax Tree
public final class Parser {
    
    // MARK: - Properties
    
    private let tokens: [Token]
    private var current: Int = 0
    private let diagnostics: DiagnosticCollector

    /// True while a where-condition is being parsed, where a trailing
    /// `default` belongs to the query modifier (ARO-0018) rather than to the
    /// expression-level defaulting operator (GitLab #547).
    fileprivate var defaultOperatorSuppressed = false


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
        let path = parseImportPath()

        if path.isEmpty {
            throw ParserError.unexpectedToken(expected: "import path", got: peek())
        }

        return ImportDeclaration(
            path: path,
            span: startToken.span.merged(with: previous().span)
        )
    }

    /// Grammar:
    ///   importPath := pathSegment ('/' pathSegment | '.' | '-')*
    ///   pathSegment := identifier | '.' | '..'
    ///
    /// Stitches lexer tokens (\`.\`, \`/\`, \`-\`, identifiers) into a
    /// single dotted/slashed path string. Stops at the first
    /// non-path token; returns "" when the cursor isn't on a
    /// path-shaped token at all (caller treats that as a parse
    /// error). Documented separately from the rest of the parser
    /// so the path-stitching contract is explicit (#342).
    ///
    /// Lifting the whole `../../foo/bar` form into a dedicated
    /// lexer token is a follow-up — that would let the lexer
    /// hand the parser one `.importPath(text:)` token instead of
    /// this peek-and-rebuild loop, but means teaching the lexer
    /// when an identifier-shaped token is actually part of a
    /// path (only after the `import` keyword).
    private func parseImportPath() -> String {
        var fragments: [String] = []
        while !isAtEnd && !check(.leftParen) && !check(.import) {
            switch peek().kind {
            case .dot:
                fragments.append(".")
                advance()
            case .slash:
                fragments.append("/")
                advance()
            case .identifier(let name):
                fragments.append(name)
                advance()
            case .hyphen:
                fragments.append("-")
                advance()
            default:
                return fragments.joined()
            }
        }
        return fragments.joined()
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
        let rawActivity = try parseIdentifierSequence()
        if rawActivity.isEmpty {
            throw ParserError.missingBusinessActivity(at: peek().span.start)
        }

        // ARO-0081: User-defined actions use `Action [takes <field[: Type]>]` headers.
        // `parseIdentifierSequence` collapses the header to "Action takes<field>" or
        // "Action takes<field:Type>" — the angle-bracket suffix logic concatenates
        // tokens between `<` and `>` without spaces. Recover the structured form here.
        let (activity, userActionTakesField, userActionTakesType) = Self.splitUserActionHeader(rawActivity)

        try expect(.rightParen, message: "')'")

        // Parse optional when/where clause for feature set guards (e.g., Handler when/where condition)
        var whenCondition: (any Expression)? = nil
        if check(.when) || check(.where) {
            advance() // consume 'when' or 'where'
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
                let errorStart = peek().span
                let skipped = synchronizeToNextStatementCollecting()
                let errorSpan = skipped.isEmpty ? errorStart : errorStart.merged(with: skipped.last!.span)
                statements.append(ErrorStatement(
                    message: error.message,
                    skippedTokens: skipped,
                    span: errorSpan
                ))
            }
        }

        let endToken = try expect(.rightBrace, message: "'}'")

        return FeatureSet(
            name: name,
            businessActivity: activity,
            statements: statements,
            whenCondition: whenCondition,
            userActionTakesField: userActionTakesField,
            userActionTakesType: userActionTakesType,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Decompose a raw activity string into `(activity, takesField, takesType)`.
    ///
    /// The lexer + `parseIdentifierSequence` collapses `Action takes <number: Integer>`
    /// to `"Action takes<number:Integer>"`. This helper restores the structured
    /// form and rejects malformed `takes` clauses without affecting non-Action
    /// activities (which pass through unchanged).
    static func splitUserActionHeader(_ raw: String) -> (activity: String, takes: String?, type: String?) {
        let prefix = "Action takes<"
        if raw.hasPrefix(prefix), raw.hasSuffix(">") {
            let inner = String(raw.dropFirst(prefix.count).dropLast())
            if let colonIdx = inner.firstIndex(of: ":") {
                let field = String(inner[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let typeName = String(inner[inner.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                return ("Action", field.isEmpty ? nil : field, typeName.isEmpty ? nil : typeName)
            }
            let field = inner.trimmingCharacters(in: .whitespaces)
            return ("Action", field.isEmpty ? nil : field, nil)
        }
        return (raw, nil, nil)
    }
    
    // MARK: - Statement Parsing

    /// Parses a statement (ARO, Publish, Require, Match, or ForEach)
    /// A statement-level parse rule. The leading keyword token has already
    /// been matched by `statementDispatch`; the parselet consumes it (and any
    /// lookahead it needs) and produces the corresponding `Statement`.
    private typealias StatementParselet = @Sendable (Parser) throws -> Statement

    /// Centralized statement dispatch table (#337).
    ///
    /// This is THE single place that maps a *leading keyword token* to the
    /// statement parser it selects. Introducing a statement form that begins
    /// with a dedicated keyword is one entry here — no other method changes,
    /// and the dispatch strategy is data rather than an implicit `if`/`switch`
    /// chain. It mirrors the infix `binaryPrecedence` table (#348) so all
    /// primary parse-rule selection lives in explicit tables.
    ///
    /// Tokens NOT listed here (action verbs, identifiers, `<`, literals, …)
    /// fall through to the default ARO action-statement / `|>` pipeline path
    /// documented in `parseStatement`. Entries are matched by `TokenKind`
    /// equality; keys are payload-free keyword kinds, so the scan is exact.
    /// `for` appears twice because the lexer may emit it as either the `.for`
    /// keyword or `.preposition(.for)`.
    private static let statementDispatch: [(match: TokenKind, parse: StatementParselet)] = [
        (.match,             { try $0.parseMatchStatement() }),               // ARO-0004
        (.when,              { try $0.parseWhenBlock() }),                     // GitLab #516
        (.for,               { try $0.parseForOrRangeLoop() }),               // ARO-0005 / ARO-0072
        (.preposition(.for), { try $0.parseForOrRangeLoop() }),
        (.parallel,          { try $0.parseParallelForEachLoop() }),
        (.while,             { try $0.parseWhileLoop() }),                    // ARO-0002 / GitLab #131
        (.break,             { try $0.parseBreakStatement() }),
        (.publish,           { try $0.parsePublishStatementForm() }),
        (.require,           { try $0.parseRequireStatementForm() }),         // ARO-0003
    ]

    private func parseStatement() throws -> Statement {
        // Centralized keyword dispatch (#337): the leading token selects a
        // dedicated statement parser. See `statementDispatch`.
        let kind = peek().kind
        if let rule = Parser.statementDispatch.first(where: { $0.match == kind }) {
            return try rule.parse(self)
        }

        // Default path: an ARO action statement (action without angle
        // brackets), optionally continuing into a `|>` pipeline. This is the
        // fallthrough for every token not claimed by a keyword rule above.
        // ARO-0067: Don't expect dot yet - check for pipeline first.
        let statement = try parseAROStatement(expectDot: false)

        // ARO-0067: Check for pipeline operator |>
        if check(.pipe) {
            return try parsePipelineStatement(initial: statement)
        }

        // Not a pipeline, expect the terminating dot
        try expectStatementTerminator()

        return statement
    }

    /// Parses a for-each loop (ARO-0005) or a range loop (ARO-0072).
    ///
    /// `for` can be tokenized as either the `.for` keyword or
    /// `.preposition(.for)`. Disambiguation needs one token of lookahead:
    /// `for each …` / bare `for …` is a for-each loop, `for <var> from …` is
    /// a range loop.
    private func parseForOrRangeLoop() throws -> Statement {
        let savedPos = current
        advance() // consume 'for'
        if check(.each) {
            current = savedPos
            return try parseForEachLoop(isParallel: false)
        } else if check(.leftAngle) {
            current = savedPos
            return try parseRangeLoop()
        } else {
            current = savedPos
            return try parseForEachLoop(isParallel: false)
        }
    }

    /// Parses a `break` statement (exits the innermost while loop).
    private func parseBreakStatement() throws -> Statement {
        let tok = try expect(.break, message: "'break'")
        try expectStatementTerminator()
        return BreakStatement(span: tok.span)
    }

    /// Consumes the leading `Publish` keyword and parses the publish form.
    private func parsePublishStatementForm() throws -> Statement {
        let startToken = advance()
        return try parsePublishStatement(startToken: startToken)
    }

    /// Consumes the leading `Require` keyword and parses the require form.
    private func parseRequireStatementForm() throws -> Statement {
        let startToken = advance()
        return try parseRequireStatement(startToken: startToken)
    }

    /// Parses pipeline statement: statement |> statement |> statement .
    /// ARO-0067: Each stage after the first operates on the result from the previous stage
    private func parsePipelineStatement(initial: AROStatement) throws -> PipelineStatement {
        let startSpan = initial.span
        var stages: [AROStatement] = [initial]

        // Parse pipeline stages (all without expecting dots)
        while check(.pipe) {
            advance() // consume |>

            // Parse next stage - it operates on the previous stage's result
            // Don't expect dot because pipeline continues
            let nextStage = try parseAROStatement(expectDot: false)
            stages.append(nextStage)
        }

        // Expect dot after all pipeline stages
        let endToken = try expectStatementTerminator()

        return PipelineStatement(
            stages: stages,
            span: startSpan.merged(with: endToken.span)
        )
    }
    
    /// Parses: Action [article] "<" result ">" preposition [article] "<" object ">" ["when" condition] "."
    /// ARO-0002: Also supports expressions after prepositions like `from <x> * <y>` or `to 30`
    /// ARO-0004: Also supports guarded statements with `when` clause
    /// ARO-0043: Also supports sink syntax like `Log "message" to the <console>.`
    /// ARO-0067: When expectDot is false, doesn't consume the terminating dot (for pipeline stages)
    private func parseAROStatement(expectDot: Bool = true) throws -> AROStatement {
        let startToken = peek()

        // 1. Action verb
        let action = try parseActionVerb()

        // 2. Result (sink syntax or standard <result>)
        var (result, resultExpression) = try parseAROResult(action: action)

        // 3. Preposition
        let prep = try parsePreposition()

        // 4. Object (expression or standard <object>)
        var (objectNoun, expression) = try parseAROObject(preposition: prep)

        // 5. Optional trailing clauses
        let clauses = try parseOptionalClauses(
            objectNoun: &objectNoun, expression: &expression,
            result: &result, verb: action.verb)

        // 6. Terminating dot
        let endToken: Token
        if expectDot {
            endToken = try expectStatementTerminator()
        } else {
            endToken = previous()
        }

        // 7. Build AST node
        let valueSource: ValueSource
        if let resExpr = resultExpression {
            valueSource = .sinkExpression(resExpr)
        } else if let expr = expression {
            valueSource = .expression(expr)
        } else {
            valueSource = .none
        }

        return AROStatement(
            action: action,
            result: result,
            object: ObjectClause(preposition: prep, noun: objectNoun),
            valueSource: valueSource,
            queryModifiers: clauses.queryModifiers,
            rangeModifiers: clauses.rangeModifiers,
            statementGuard: clauses.guard_,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    // MARK: - parseAROStatement Submethods
    //
    // Shared cursor contract (#341)
    // -----------------------------
    // Every helper below consumes a contiguous slice of the
    // token stream starting at `current`. On success, `current`
    // advances past the last token the helper consumed. On
    // failure (throws), `current` is left at the token the
    // helper expected to consume but didn't recognise — so the
    // caller can choose to recover (via `synchronize()`) or
    // re-raise.
    //
    // Pre/post-condition summary (each helper repeats its
    // contract in its own doc comment):
    //
    //   parseActionVerb()        — pre: cursor on an action-shaped token
    //                              (capitalised identifier, or one of the
    //                              `when`/`then`/`assert`/`exists` keywords).
    //                              Walks any `Namespace.Verb` chain too.
    //                              post: cursor on the next token.
    //
    //   parseAROResult(action:)  — pre: cursor on either a sink expression
    //                              (when `action` is a sink verb), or
    //                              `[article] <result>`.
    //                              post: cursor on the preposition that
    //                              follows.
    //
    //   parsePreposition()       — pre: cursor on a preposition token.
    //                              post: cursor on the next token.
    //
    //   parseAROObject(prep:)    — pre: cursor on an object position —
    //                              `[article] <object>` or, for `to/from/
    //                              with/for`, optionally an expression
    //                              that isn't an object pattern.
    //                              post: cursor on the next token (which
    //                              is usually `.` or a clause keyword).
    //
    //   parseArticleIfPresent()  — pre: cursor anywhere; helper is a no-op
    //                              if the current token is not `.article`.
    //                              post: cursor after the article when one
    //                              was present.
    //
    //   parseQueryModifiers()    — pre: cursor on `where`/`order`/`limit`
    //                              or any other valid post-object clause.
    //                              post: cursor immediately after the last
    //                              consumed clause; no-op if none start.

    /// Parses the action verb (capitalized identifier, keyword, or Namespace.Verb syntax)
    ///
    /// Pre: cursor on a capitalised identifier or a `when`/`then`/
    /// `assert`/`exists` keyword.
    /// Post: cursor advanced past the verb and any `Namespace.Verb`
    /// suffix.
    /// Throws: `unexpectedToken` when the cursor isn't on a
    /// verb-shaped token — `current` is left pointing at it so
    /// the caller can recover.
    private func parseActionVerb() throws -> Action {
        switch peek().kind {
        case .when, .then, .assert, .exists:
            let actionToken = advance()
            let capitalizedVerb = actionToken.lexeme.prefix(1).uppercased() + actionToken.lexeme.dropFirst()
            return Action(verb: capitalizedVerb, span: actionToken.span)
        case .identifier(let verb) where verb.first?.isUppercase == true:
            let actionToken = advance()
            var fullVerb = actionToken.lexeme
            var endSpan = actionToken.span
            // GitLab #95: Handle Namespace.Verb dotted syntax (e.g., Markdown.ToHTML)
            while case .dot = peek().kind {
                let savedPosition = current
                advance() // consume dot
                if case .identifier(let part) = peek().kind, part.first?.isUppercase == true {
                    let partToken = advance()
                    fullVerb += "." + partToken.lexeme
                    endSpan = partToken.span
                } else {
                    current = savedPosition
                    break
                }
            }
            return Action(verb: fullVerb, span: actionToken.span.merged(with: endSpan))
        default:
            throw ParserError.unexpectedToken(expected: "action verb (e.g., Extract, Filter, Return)", got: peek())
        }
    }

    /// Parses the result position: sink syntax (ARO-0043) or standard `[article] <result>`
    /// Returns the result noun and an optional sink expression
    private func parseAROResult(action: Action) throws -> (QualifiedNoun, (any Expression)?) {
        let isSinkVerb = isSinkActionVerb(action.verb)
        let useSinkSyntax = isSinkVerb && isSinkSyntaxStart(peek())

        if useSinkSyntax {
            let expr = try parseExpression()
            let result = QualifiedNoun(base: "_sink_", specifiers: [], span: previous().span)
            return (result, expr)
        }

        // Standard syntax: [article] <result>
        if case .article = peek().kind { advance() }
        try expect(.leftAngle, message: "'<'")
        var result = try parseQualifiedNoun()
        try expect(.rightAngle, message: "'>'")

        // ARO-0038: optional 'as Type' annotation.
        // Recorded in `asType`, NOT by overwriting `typeAnnotation` — the
        // qualifier selects the operation and `as` requests the result type, so
        // clobbering one with the other silently changed what the statement
        // computed (GitLab #475).
        if check(.as) {
            advance()
            let asType = try parseTypeAnnotation()
            result = QualifiedNoun(
                base: result.base,
                typeAnnotation: result.typeAnnotation,
                span: result.span,
                asType: asType
            )
        }

        return (result, nil)
    }

    /// Parses the preposition between result and object
    private func parsePreposition() throws -> Preposition {
        if case .preposition(let p) = peek().kind {
            advance()
            return p
        } else if case .for = peek().kind {
            advance()
            return .for
        }
        throw ParserError.unexpectedToken(expected: "preposition", got: peek())
    }

    /// Parses the object position: expression or standard `[article] <object>`
    /// Returns the object noun and an optional expression
    /// HTTP methods accepted between `via` and the object
    /// (ARO-0008 §3.3).
    private static let httpMethodWords: Set<String> = [
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS",
    ]

    private func parseAROObject(preposition prep: Preposition) throws -> (QualifiedNoun, (any Expression)?) {
        // `Request the <result> via PUT the <url> with <data>.`
        // (ARO-0008 §3.3, GitLab #464). The method is a bare word
        // between the preposition and the object, so without this
        // `PUT` was consumed *as* the object and the statement died
        // on the article that followed it.
        //
        // It lands in the object's specifiers because that is where
        // `RequestAction` already looks — `case .via:
        // object.specifiers.first` has been there all along. Only
        // the syntax was missing.
        if prep == .via,
           case .identifier(let word) = peek().kind,
           Self.httpMethodWords.contains(word.uppercased()),
           let next = peekAt(1),
           next.kind.isArticle || next.kind == .leftAngle
        {
            let methodToken = advance()
            if case .article = peek().kind { advance() }
            if check(.leftAngle) {
                advance()
                let noun = try parseQualifiedNoun()
                let close = try expect(.rightAngle, message: "'>'")
                return (
                    QualifiedNoun(
                        base: noun.base,
                        // Method first: the runtime reads
                        // `specifiers.first`, and a qualifier the
                        // author wrote on the object still follows.
                        specifiers: [methodToken.lexeme.uppercased()] + noun.specifiers,
                        span: methodToken.span.merged(with: close.span)),
                    nil
                )
            }
            let startSpan = peek().span
            let base = try parseCompoundIdentifier()
            return (
                QualifiedNoun(
                    base: base,
                    specifiers: [methodToken.lexeme.uppercased()],
                    span: startSpan.merged(with: previous().span)),
                nil
            )
        }

        let shouldParseExpression = (prep == .to || prep == .from || prep == .with || prep == .for) && isExpressionStart(peek())

        if shouldParseExpression && !isObjectPattern() {
            let expression = try parseExpression()

            // Time-unit suffix for duration literals (GitLab #502).
            // The vocabulary lives in DurationUnitCatalog so the
            // parser, SleepAction and the check-time lint cannot
            // drift apart. `300ms` lexes as `300` + `ms`, so the
            // spaced and unspaced spellings arrive here identically.
            if (prep == .with || prep == .for), case .identifier(let unit) = peek().kind, DurationUnitCatalog.isUnit(unit) {
                advance()
                return (QualifiedNoun(base: unit, specifiers: [], span: previous().span), expression)
            }
            return (QualifiedNoun(base: "_expression_", specifiers: [], span: previous().span), expression)
        }

        // Standard syntax: [article] <object> or bare identifier
        if case .article = peek().kind { advance() }

        if check(.leftAngle) {
            advance()
            let objectNoun = try parseQualifiedNoun()
            try expect(.rightAngle, message: "'>'")
            return (objectNoun, nil)
        } else if case .identifier = peek().kind {
            let startSpan = peek().span
            let base = try parseCompoundIdentifier()
            return (QualifiedNoun(base: base, specifiers: [], span: startSpan.merged(with: previous().span)), nil)
        }

        throw ParserError.unexpectedToken(expected: "object ('<' or identifier)", got: peek())
    }

    /// Intermediate storage for parsed optional clauses
    private struct AROClauses {
        var queryModifiers: QueryModifiers
        var rangeModifiers: RangeModifiers
        var guard_: StatementGuard
    }

    /// Parses optional trailing clauses: with, to, where, by, default, when
    private func parseOptionalClauses(
        objectNoun: inout QualifiedNoun,
        expression: inout (any Expression)?,
        result: inout QualifiedNoun,
        verb: String
    ) throws -> AROClauses {
        var aggregation: AggregationClause? = nil
        var withExpression: (any Expression)? = nil
        var toExpression: (any Expression)? = nil
        var againstExpression: (any Expression)? = nil
        var whereCondition: WhereCondition? = nil
        var byClause: ByClause? = nil
        var defaultValue: (any Expression)? = nil
        var matchingPattern: (any Expression)? = nil
        var recursive = false
        var whenCondition: (any Expression)? = nil

        // `Map the <names> from the <users> with name.` — the field
        // projection spelling documented in ARO-0019 §2.1, and used
        // again in ARO-0051 and ARO-0086 (GitLab #465). It did not
        // parse at all: a bare identifier is not an expression start,
        // so the with-clause fell through and the statement died on
        // "Expected '.', but got identifier(name)".
        //
        // Desugared into the specifier form that already works —
        // `Map the <names: name> from the <users>.` — so MapAction
        // needs no change and the two spellings cannot drift apart.
        // Scoped to Map by verb: a bare identifier after `with` is a
        // parse error for every other verb and stays one.
        if verb.lowercased() == "map",
           case .preposition(.with) = peek().kind,
           let next = peekAt(1), case .identifier = next.kind,
           !isExpressionStart(next)
        {
            advance()
            let fieldToken = advance()
            result = QualifiedNoun(
                base: result.base,
                typeAnnotation: fieldToken.lexeme,
                span: result.span.merged(with: fieldToken.span))
        }

        // with clause (ARO-0042)
        if case .preposition(.with) = peek().kind {
            advance()
            if let agg = try parseAggregationIfPresent() {
                aggregation = agg
            } else if isExpressionStart(peek()) {
                withExpression = try parseExpression()
                if objectNoun.base != "_expression_" {
                    expression = withExpression
                }
            }
        }

        // to clause (ARO-0041)
        if case .preposition(let p) = peek().kind, p == .to {
            advance()
            toExpression = try parseExpression()
        }

        // against clause (GitLab #469) — Compare's right-hand
        // operand, so `Compare the <same> from the <a> against the
        // <b>.` can bind a fresh result instead of trying to
        // rebind its own first operand.
        if case .preposition(.against) = peek().kind {
            advance()
            // Articles are optional everywhere else in ARO, and
            // every documented Compare writes `against the <b>`.
            if case .article = peek().kind { advance() }
            againstExpression = try parseExpression()
        }

        // where clause (ARO-0018)
        if check(.where) {
            advance()
            whereCondition = try parseWhereCondition()
        }

        // by clause (ARO-0037)
        if case .preposition(.by) = peek().kind {
            let byToken = advance()
            if case .regexLiteral(let pattern, let flags) = peek().kind {
                advance()
                byClause = ByClause(pattern: pattern, flags: flags, span: byToken.span.merged(with: previous().span))
            } else if case .stringLiteral(let fieldName) = peek().kind {
                advance()
                byClause = ByClause(pattern: fieldName, flags: "", span: byToken.span.merged(with: previous().span), isFieldName: true)
            } else if case .leftAngle = peek().kind {
                // `by <var>` — the pattern is whatever string the variable
                // resolves to at runtime; lets data files drive Split/Group.
                advance()
                guard case .identifier(var name) = peek().kind else {
                    throw ParserError.unexpectedToken(expected: "identifier inside <…> after 'by'", got: peek())
                }
                advance()
                // Hyphenated names — `by <field-name>` (GitLab #491); the
                // single-identifier parse rejected what every other <…>
                // position accepts.
                while check(.hyphen) {
                    advance()
                    guard case .identifier(let segment) = peek().kind else {
                        throw ParserError.unexpectedToken(expected: "identifier after '-' in 'by <…>'", got: peek())
                    }
                    advance()
                    name += "-" + segment
                }
                try expect(.rightAngle, message: "Expected '>' after variable name in 'by <…>'")
                byClause = ByClause(
                    pattern: "",
                    flags: "",
                    span: byToken.span.merged(with: previous().span),
                    variableName: name
                )
            } else {
                throw ParserError.unexpectedToken(expected: "regex literal, string literal, or <var> after 'by'", got: peek())
            }

            // Trailing sort order — `by <score> descending` (ARO-0002
            // §Ordering, GitLab #491). Only these two words are consumed;
            // anything else stays for the clauses that follow.
            if case .identifier(let word) = peek().kind,
               let order = SortOrder(rawValue: word),
               let clause = byClause {
                advance()
                byClause = ByClause(
                    pattern: clause.pattern,
                    flags: clause.flags,
                    span: clause.span.merged(with: previous().span),
                    isFieldName: clause.isFieldName,
                    variableName: clause.variableName,
                    order: order
                )
            }
        }

        // matching clause (ARO-0036 §6.2, GitLab #518) — the glob filter on a
        // directory listing: `List the <exports> from the <directory: out>
        // matching "*.csv".`  `matching` is not a reserved word, so it is
        // recognised positionally, exactly like `default` below; a variable
        // (`matching <pattern>`) works because the glob is parsed as an
        // expression rather than a bare literal.
        if case .identifier(let kw) = peek().kind, kw == "matching" {
            advance()
            guard isExpressionStart(peek()) else {
                throw ParserError.unexpectedToken(
                    expected: "glob pattern after 'matching' — a string like \"*.csv\" or a <variable>",
                    got: peek())
            }
            matchingPattern = try parseExpression()
        }

        // trailing `recursively` (ARO-0036 §6.3) — the spelling the proposal
        // documents next to `matching`, and the one people write after it:
        // `… matching "*_test.aro" recursively.`  The older qualifier form
        // (`List the <all: recursively> from …`) still works.
        if case .identifier(let kw) = peek().kind, kw == "recursively" {
            advance()
            recursive = true
        }

        // default clause (ARO-0072)
        if case .identifier(let kw) = peek().kind, kw == "default" {
            advance()
            defaultValue = try parseExpression()
        }

        // when clause (ARO-0004)
        if check(.when) {
            advance()
            whenCondition = try parseExpression()
        }

        return AROClauses(
            queryModifiers: QueryModifiers(
                whereCondition: whereCondition,
                aggregation: aggregation,
                byClause: byClause,
                defaultValue: defaultValue,
                matchingPattern: matchingPattern,
                recursive: recursive
            ),
            rangeModifiers: RangeModifiers(
                toClause: toExpression,
                withClause: withExpression,
                againstClause: againstExpression
            ),
            guard_: StatementGuard(condition: whenCondition)
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
    /// Sink syntax: `Log "message"` or `Log <data>` (without preceding article)
    private func isSinkSyntaxStart(_ token: Token) -> Bool {
        // Sink syntax starts with:
        // 1. String literal: `Log "message"`
        // 2. Numeric/boolean/nil literal: `Log 42`, `Log true` (GitLab #512)
        // 3. Object/array literal: <Log> { key: value } or <Log> [1, 2, 3]
        // 4. Variable reference (without article): <Log> <data>
        //    Note: Standard syntax has article: <Log> the <result>
        switch token.kind {
        case .stringLiteral, .intLiteral, .floatLiteral, .true, .false, .nil, .null:
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

    /// Check if current position looks like an object pattern (not an expression)
    /// An object pattern requires an article: "the <x>" or "an <x>" or bare identifier "console"
    /// Without article, <x> is treated as an expression (variable reference)
    private func isObjectPattern() -> Bool {
        // Case 1: article followed by < or identifier = object
        if case .article = peek().kind {
            return true
        }
        // Case 2: bare identifier (no angle brackets, no article) = object
        if case .identifier = peek().kind {
            return true
        }
        // Case 3: <identifier: ...> = system object (e.g., <file: "path">, <url: "...">)
        // This allows optional article before system objects
        if check(.leftAngle) {
            // Look ahead: < identifier : ... > means system object
            if case .identifier = peekAt(1)?.kind,
               case .colon = peekAt(2)?.kind {
                // GitLab #496: unless the reference is the first operand of an
                // expression. `from <item: qty> * <item: price>` used to capture
                // `<item: qty>` as the object noun and then die on the operator
                // ("Expected '.', but got *") — forcing an Extract per operand.
                // The expression grammar already parses qualified nouns (it is
                // what string interpolation uses), so when the token after the
                // reference's closing '>' is a binary operator, route there.
                if qualifiedRefStartsExpression() {
                    return false
                }
                return true
            }
        }
        // Case 4: <...> without article and no colon = expression (not object)
        return false
    }

    /// GitLab #496: decides whether a qualified variable reference in object
    /// position (`<item: qty>`) is really the first operand of an expression.
    ///
    /// Scans from the current `<` to its matching `>` (angle depth tracks
    /// generic type parameters like `List<User>` inside the qualifier) and
    /// inspects the token that follows. A binary operator there means the
    /// statement is `... from <a: x> * <b: y> ...` — an expression — rather
    /// than a system-object noun. Angle-bracket comparisons (`<`, `>`) are
    /// deliberately absent from the operator set: they are ambiguous with
    /// variable references, matching how bare-identifier operands already
    /// behave (`infixPrecedence` refuses them before an identifier too).
    ///
    /// The scan is bounded: qualifier contents are short (identifiers, dots,
    /// chains, string literals, generic parameters). An unclosed reference
    /// falls back to the object interpretation — the standard path then
    /// reports its usual, well-tested error.
    private func qualifiedRefStartsExpression() -> Bool {
        guard check(.leftAngle) else { return false }
        var depth = 0
        var index = current
        let limit = min(tokens.count, current + 64)
        while index < limit {
            switch tokens[index].kind {
            case .leftAngle, .lessThan:
                depth += 1
            case .rightAngle, .greaterThan:
                depth -= 1
                if depth == 0 {
                    guard index + 1 < tokens.count else { return false }
                    switch tokens[index + 1].kind {
                    case .plus, .minus, .hyphen, .star, .slash, .percent,
                         .plusPlus, .equalEqual, .bangEqual, .lessEqual,
                         .greaterEqual, .and, .or, .contains, .matches:
                        return true
                    // `<params: count> default 3` is an expression, not an
                    // object with a query modifier (GitLab #547): read as an
                    // object it bound the whole record and dropped the
                    // fallback, which is the misbehaviour #547 reported.
                    // Inside a where-condition `default` still belongs to the
                    // query (ARO-0018), and there the operator is suppressed.
                    //
                    // Framework objects stay objects. `<file: "notes.md">` is
                    // an *address* an action resolves, not a value an
                    // expression can read, so routing `Read the <c> from the
                    // <file: "x"> default "y".` through the expression grammar
                    // would find no variable called `file` and hand back the
                    // default every time — a silent wrong answer, the very
                    // thing #547 is about. `parameter` and `env` are the
                    // exceptions: both evaluators resolve them, so a missing
                    // `--port` really is an absent value.
                    case .identifier("default"):
                        guard !defaultOperatorSuppressed else { return false }
                        let base = qualifiedRefBase().lowercased()
                        return !SystemObjectCatalog.isSystemObject(base)
                            || SystemObjectCatalog.isValueBearing(base)
                    default:
                        return false
                    }
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// The base name of the `<base: qualifier>` reference at the current `<`,
    /// hyphenated segments joined (`user-repository`), or "" when the tokens
    /// do not form one. Used to ask `SystemObjectCatalog` what kind of thing
    /// the reference names.
    private func qualifiedRefBase() -> String {
        guard check(.leftAngle) else { return "" }
        var index = current + 1
        var base = ""
        while index < tokens.count {
            if case .identifier(let part) = tokens[index].kind {
                base += part
                index += 1
                if index < tokens.count, case .hyphen = tokens[index].kind {
                    base += "-"
                    index += 1
                    continue
                }
            }
            break
        }
        return base
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
        case "first": aggType = .first
        case "last": aggType = .last
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

    /// Parses a where condition per ARO-0018 §7 (GitLab #498):
    ///
    ///     predicate     = predicate_or ;
    ///     predicate_or  = predicate_and , { "or" , predicate_and } ;
    ///     predicate_and = predicate_atom , { "and" , predicate_atom } ;
    ///     predicate_atom = comparison | "(" , predicate , ")" ;
    ///
    /// `and` binds tighter than `or`, so `a or b and c` reads as
    /// `a or (b and c)` — same precedence as the expression grammar.
    private func parseWhereCondition() throws -> WhereCondition {
        // A `default` after a where-condition is the query modifier
        // (`… where <id> is 5 default "none".`), never the expression-level
        // defaulting operator — otherwise the predicate's value would swallow
        // it and `_default_value_` would never be bound (GitLab #547).
        let previouslySuppressed = defaultOperatorSuppressed
        defaultOperatorSuppressed = true
        defer { defaultOperatorSuppressed = previouslySuppressed }

        var left = try parseWhereAndCondition()
        while check(.or) {
            advance()
            let right = try parseWhereAndCondition()
            left = .or(left, right)
        }
        return left
    }

    private func parseWhereAndCondition() throws -> WhereCondition {
        var left = try parseWhereAtom()
        while check(.and) {
            advance()
            let right = try parseWhereAtom()
            left = .and(left, right)
        }
        return left
    }

    private func parseWhereAtom() throws -> WhereCondition {
        // Parenthesized group: where (<a> is 1 or <b> is 2) and <c> is 3
        if check(.leftParen) {
            advance()
            let grouped = try parseWhereCondition()
            try expect(.rightParen, message: "')' to close the parenthesized where condition")
            return grouped
        }
        return try parseWherePredicate()
    }

    /// Parses one comparison: <field> is "value" or <field> > 1000.
    ///
    /// The value expression is parsed *above* the logical operators
    /// (`parsePrecedence(.and)`), so a following `and`/`or` starts the
    /// next predicate instead of being swallowed into the value — that
    /// swallowing is exactly what turned
    /// `where <status> == "paid" and <qty> > 2` into a runtime
    /// "Undefined variable: qty" (GitLab #498). A value that really is
    /// a logical expression can still be written in parentheses.
    ///
    /// `between lo and hi` (ARO-0018 §2.1) desugars right here into
    /// `field >= lo and field <= hi` — the runtime never sees it.
    ///
    /// The field may be written `<status>` or bare `status` (ARO-0018
    /// §7, GitLab #545). Every proposal has printed the bare spelling
    /// for years — ARO-0019 §2.1, ARO-0003, ARO-0006's whole worked
    /// example — while the parser demanded the brackets, so the
    /// documented examples did not parse. A where clause's left-hand
    /// side is a field of the row being tested and nothing else, so
    /// there is nothing for a bare name to be confused with here.
    private func parseWherePredicate() throws -> WhereCondition {
        let startSpan = peek().span

        // Parse field: <field> or bare field (GitLab #545)
        let field = try parseWhereFieldReference()

        // between: desugared into two predicates on the same field
        if case .identifier(let word) = peek().kind, word.lowercased() == "between" {
            advance()
            let low = try parsePrecedence(.and)
            guard check(.and) else {
                throw ParserError.unexpectedToken(
                    expected: "'and' between the lower and upper bound of 'between'",
                    got: peek()
                )
            }
            advance()
            let high = try parsePrecedence(.and)
            let lowClause = WhereClause(
                field: field, op: .greaterEqual, value: low,
                span: startSpan.merged(with: low.span))
            let highClause = WhereClause(
                field: field, op: .lessEqual, value: high,
                span: startSpan.merged(with: high.span))
            return .and(.predicate(lowClause), .predicate(highClause))
        }

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
        case .lessEqual:
            advance()
            op = .lessEqual
        case .greaterThan, .rightAngle:
            advance()
            if check(.equals) {
                advance()
                op = .greaterEqual
            } else {
                op = .greaterThan
            }
        case .greaterEqual:
            advance()
            op = .greaterEqual
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
        case .identifier(let word) where word.lowercased() == "starts"
                                      || word.lowercased() == "ends":
            let isStarts = word.lowercased() == "starts"
            advance()
            try expectPreposition(.with, message: "'with' after '\(word)'")
            op = isStarts ? .startsWith : .endsWith
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
            throw ParserError.unexpectedToken(expected: "comparison operator (is, =, <, >, <=, >=, !=, contains, matches, starts with, ends with, in, not in, between) after <\(field)> in where clause", got: peek())
        }

        // Parse value expression — stops before and/or (see doc comment)
        let value = try parsePrecedence(.and)

        return .predicate(WhereClause(field: field, op: op, value: value, span: startSpan.merged(with: value.span)))
    }

    /// Parses a where-clause field reference — ARO-0018 §7's
    /// `field_reference`, in either spelling (GitLab #545):
    ///
    ///     field_reference = "<" , field_name , ">" | field_name ;
    ///
    /// `where <status> is "active"` and `where status is "active"` are
    /// the same clause and produce the same `WhereClause`, so the
    /// interpreter and the compiled binary — which bind the identical
    /// tree through `ModifierBinder` — cannot disagree about them.
    ///
    /// Hyphenated names work bare too (`where customer-id = <id>`):
    /// outside a number, `-` always lexes as `.hyphen`, so the same
    /// `parseCompoundIdentifier` serves both spellings.
    ///
    /// This bare form is confined to the ARO-0018 where clause, whose
    /// left-hand side can only ever be a field of the row under test.
    /// The `where` that guards a `for each` header, a `match` case, or
    /// a feature-set header is an ordinary boolean *expression*, where
    /// a bare name would be a variable reference rather than a field —
    /// those stay angle-only.
    private func parseWhereFieldReference() throws -> String {
        if check(.leftAngle) {
            advance()
            let field = try parseCompoundIdentifier()
            try expect(.rightAngle, message: "'>'")
            return field
        }

        guard peek().kind.isIdentifierLike else {
            throw ParserError.unexpectedToken(
                expected: "a field name in the where clause — `<status>` or `status`",
                got: peek()
            )
        }
        return try parseCompoundIdentifier()
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
            return try parseArrayLiteralValue()
        case .leftBrace:
            return try parseObjectLiteral()
        default:
            throw ParserError.unexpectedToken(expected: "literal value", got: token)
        }
    }

    /// Parses: "[" [ literal { "," literal } ] "]" — the literal form.
    private func parseArrayLiteralValue() throws -> LiteralValue {
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

    /// Continues a key that began with `first`, absorbing `-word` runs.
    ///
    /// `{ created-at: … }` is one key, not a subtraction (GitLab #579, #583),
    /// and any word-shaped token may follow the hyphen — keywords included,
    /// since a field named `order` or `from` is perfectly ordinary JSON. Both
    /// the literal form (`parseObjectField`) and the expression form
    /// (`parseMapEntry`) carried their own copy of this loop.
    private func parseHyphenatedKey(startingWith first: String) throws -> String {
        var key = first
        while check(.hyphen) {
            advance() // consume hyphen
            key += "-"
            if peek().isWordShaped {
                key += advance().lexeme
            } else {
                throw ParserError.unexpectedToken(expected: "identifier after hyphen", got: peek())
            }
        }
        return key
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
            key = try parseHyphenatedKey(startingWith: name)
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

        // Trailing `when` guard, the same clause action statements take
        // (GitLab #830 item 14).
        var whenCondition: (any Expression)?
        if check(.when) {
            advance()
            whenCondition = try parseExpression()
        }

        let endToken = try expectStatementTerminator()

        return PublishStatement(
            externalName: externalName,
            internalVariable: internalVariable,
            statementGuard: StatementGuard(condition: whenCondition),
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
        try expectPreposition(.from, message: "'from'")

        // Skip optional article before source
        if case .article = peek().kind {
            advance()
        }

        try expect(.leftAngle, message: "'<'")
        let sourceName = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        let endToken = try expectStatementTerminator()

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
    /// Parses: `when` condition `{` { statement } `}`
    ///
    /// The suffix form (`Log … when <x> is <y>.`) is parsed inside a
    /// statement and is untouched; this is the block spelling the
    /// Language Guide uses when several statements share a condition.
    private func parseWhenBlock() throws -> Statement {
        // `When the <len> from the <get-length>.` is ARO-0015's test
        // statement, where `When` is the action verb — not a guarded
        // block. An article can only follow the verb; a block's
        // condition starts with `<`, an identifier, a literal, `(` or
        // `not`. Checking that one token keeps both spellings, which
        // is what the Given/When/Then suites depend on.
        if case .article = peekAt(1)?.kind {
            return try parseAROStatement()
        }
        let startToken = try expect(.when, message: "'when'")
        let condition = try parseExpression()
        try expect(.leftBrace, message: "'{' to open the when block")

        var body: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            body.append(try parseStatement())
        }
        let endToken = try expect(.rightBrace, message: "'}' to close the when block")

        return WhenStatement(
            condition: condition,
            body: body,
            span: startToken.span.merged(with: endToken.span)
        )
    }

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
        // Accept either .for keyword or .preposition(.for)
        let startToken: Token
        if check(.for) {
            startToken = try expect(.for, message: "'for'")
        } else if check(.preposition(.for)) {
            startToken = try expect(.preposition(.for), message: "'for'")
        } else {
            throw ParserError.unexpectedToken(expected: "'for'", got: peek())
        }
        try expect(.each, message: "'each'")

        // Parse item variable: <item>
        try expect(.leftAngle, message: "'<'")
        let itemVariable = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        // Parse optional index: at <index>
        // Note: 'at' can be tokenized as either .atKeyword or .preposition(.at)
        var indexVariable: String? = nil
        if check(.atKeyword) || check(.preposition(.at)) {
            advance()
            try expect(.leftAngle, message: "'<'")
            indexVariable = try parseCompoundIdentifier()
            try expect(.rightAngle, message: "'>'")
        }

        // Parse collection: `in <collection>` or `in <expression>` (GitLab #519).
        //
        // The noun form is tried first and kept whenever the header ends right
        // after it, because only a name can carry specifiers (<team: members>)
        // and reach the lazy-stream iteration path (ARO-0051). Anything else —
        // a list literal, a parenthesised expression, `<a>.field`, `<a> + <b>` —
        // rewinds and re-parses the whole slot as an expression, so a quick loop
        // no longer needs a Create first.
        try expect(.in, message: "'in'")
        var collection: QualifiedNoun? = nil
        var collectionExpression: (any Expression)? = nil
        let collectionStart = current
        if check(.leftAngle) {
            advance()
            let noun = try parseQualifiedNoun()
            try expect(.rightAngle, message: "'>'")
            if forEachHeaderEndsHere(isParallel: isParallel) {
                collection = noun
            } else {
                current = collectionStart
            }
        }
        if collection == nil {
            collectionExpression = try parseExpression()
        }

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
                if n <= 0 {
                    diagnostics.warning("Concurrency limit must be greater than 0, got \(n)", at: concurrencyToken.span.start)
                }
                concurrency = max(n, 1)
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

        if let collection {
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
        return ForEachLoop(
            itemVariable: itemVariable,
            indexVariable: indexVariable,
            // Safe: `collectionExpression` is assigned whenever `collection` is nil.
            collectionExpression: collectionExpression!,
            filter: filter,
            isParallel: isParallel,
            concurrency: concurrency,
            body: body,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Whether the for-each header is complete at the current token — i.e. what
    /// was just parsed as `<noun>` really was the whole collection slot.
    ///
    /// `with` only ends the header for a parallel loop, where it introduces the
    /// concurrency clause; on a sequential loop it can only be an operator-ish
    /// continuation, so the slot is re-read as an expression.
    private func forEachHeaderEndsHere(isParallel: Bool) -> Bool {
        if check(.leftBrace) || check(.where) { return true }
        if isParallel && check(.preposition(.with)) { return true }
        return false
    }

    // MARK: - While Loop Parsing (ARO-0002 extension, GitLab #131)

    /// Parses: "while" <condition> "{" statements "}"
    ///
    /// ## Syntax
    /// ```aro
    /// while <done> == false {
    ///     Create the <done> with true when <remaining> == 0.
    ///     break.
    /// }
    /// ```
    private func parseWhileLoop() throws -> WhileLoop {
        let startToken = try expect(.while, message: "'while'")

        // Parse the boolean condition expression
        let condition = try parseExpression()

        // Parse body block: { statements }
        try expect(.leftBrace, message: "'{'")
        var body: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            body.append(try parseStatement())
        }
        let endToken = try expect(.rightBrace, message: "'}'")

        return WhileLoop(
            condition: condition,
            body: body,
            span: startToken.span.merged(with: endToken.span)
        )
    }

    /// Parses: "for" "<" var ">" "from" <expr> "to" <expr> "{" statements "}"
    private func parseRangeLoop() throws -> RangeLoop {
        let startToken: Token
        if check(.for) {
            startToken = try expect(.for, message: "'for'")
        } else {
            startToken = try expect(.preposition(.for), message: "'for'")
        }

        try expect(.leftAngle, message: "'<'")
        let variable = try parseCompoundIdentifier()
        try expect(.rightAngle, message: "'>'")

        // consume 'from' (preposition)
        try expectPreposition(.from, message: "'from'")

        let fromExpr = try parseExpression()

        // consume 'to' (preposition)
        try expectPreposition(.to, message: "'to'")

        let toExpr = try parseExpression()

        try expect(.leftBrace, message: "'{'")
        var body: [Statement] = []
        while !check(.rightBrace) && !isAtEnd {
            body.append(try parseStatement())
        }
        let endToken = try expect(.rightBrace, message: "'}'")

        return RangeLoop(variable: variable, from: fromExpr, to: toExpr, body: body,
                         span: startToken.span.merged(with: endToken.span))
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
        var isLiteralQualifier = false

        if check(.colon) {
            advance()

            // ARO-0068: Check for string literal after colon (e.g., <command: "uptime">)
            // This allows commands and other values to be specified inline.
            // Flag it so the value is never mistaken for a dot-separated property
            // path — `<file: "data.json">` is the path `data.json`, not `data` → `json`.
            if case .stringLiteral(let value) = peek().kind {
                advance()
                typeAnnotation = value
                isLiteralQualifier = true
            } else {
                // Parse type annotation (ARO-0006)
                typeAnnotation = try parseTypeAnnotation()
            }
        }

        return QualifiedNoun(
            base: base,
            typeAnnotation: typeAnnotation,
            span: startToken.span.merged(with: previous().span),
            isLiteralQualifier: isLiteralQualifier
        )
    }

    /// Parses a type annotation: String | Integer | Float | Boolean | List<T> | Map<K,V> | SchemaName | DateOffset
    /// Note: This function does NOT consume the closing `>` of the enclosing variable reference.
    /// It only consumes `<` and `>` for generic type parameters like `List<User>`.
    /// Type names can be hyphenated like "password-hash" for legacy compatibility.
    /// Date offsets like "+7d", "-3h" are also supported (ARO-0041).
    private func parseTypeAnnotation() throws -> String {
        // Check for date offset pattern (ARO-0041): +7d, -3h, etc.
        if check(.plus) || check(.minus) {
            return try parseDateOffsetPattern()
        }
        if case .intLiteral(let value) = peek().kind, value < 0 {
            return try parseDateOffsetPattern()
        }

        // Check for numeric range specifier (ARO-0038): 0, 0-19, 0,3,7
        if case .intLiteral(let startValue) = peek().kind, startValue >= 0 {
            return try parseNumericSpecifier()
        }

        // `matches` is the regex comparison keyword, but it is also
        // the natural name for Compare's boolean field, and a
        // keyword in qualifier position is unambiguous — nothing
        // else can appear after the colon (GitLab #469).
        if check(.matches) {
            advance()
            return "matches"
        }

        // Parse compound identifier (may contain hyphens like "password-hash")
        var typeStr = try parseCompoundIdentifier()

        // Generic types, property paths, or file paths
        if check(.leftAngle) || check(.lessThan) {
            typeStr += try parseGenericTypeParameters()
        } else {
            typeStr += try parsePropertyOrFilePath()
        }

        // Qualifier chaining: <result: stats.sort | list.take>
        typeStr += try parseQualifierChain()

        return typeStr
    }

    /// Parses generic type parameters: `<T>` or `<K, V>`
    private func parseGenericTypeParameters() throws -> String {
        advance() // consume <
        var result = "<"
        result += try parseTypeAnnotation()
        if check(.comma) {
            advance()
            result += ", "
            result += try parseTypeAnnotation()
        }
        if check(.rightAngle) || check(.greaterThan) {
            advance()
            result += ">"
        } else {
            throw ParserError.unexpectedToken(expected: "'>'", got: peek())
        }
        return result
    }

    /// Parses dot-separated property paths or slash-separated file paths
    /// e.g., `profile.name` or `emails/welcome.tpl`
    private func parsePropertyOrFilePath() throws -> String {
        var result = ""
        while check(.dot) || check(.slash) {
            if peekAt(1)?.kind.isIdentifier == true {
                let separator = peek()
                advance()
                result += (separator.kind == .dot ? "." : "/")
                result += try parseCompoundIdentifier()
            } else {
                break
            }
        }
        return result
    }

    /// Parses qualifier chain: `| stats.sort | list.take`
    private func parseQualifierChain() throws -> String {
        var result = ""
        while check(.bar) {
            advance()
            var nextQualifier = try parseCompoundIdentifier()
            while check(.dot) {
                if peekAt(1)?.kind.isIdentifier == true {
                    advance()
                    nextQualifier += "."
                    nextQualifier += try parseCompoundIdentifier()
                } else {
                    break
                }
            }
            result += "|" + nextQualifier
        }
        return result
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
            let rangeStart = firstValue
            let rangeEnd = abs(nextValue)
            advance()
            // Convert negative to range: -19 means range end is 19
            result += "-"
            result += String(rangeEnd)
            if rangeStart > rangeEnd {
                diagnostics.warning("Range start (\(rangeStart)) is greater than end (\(rangeEnd))", at: peek().span.start)
            }
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
            if firstValue > endValue {
                diagnostics.warning("Range start (\(firstValue)) is greater than end (\(endValue))", at: peek().span.start)
            }
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
        // A reserved word is a word again inside a hyphenated name.
        //
        // The segments were each required to be a plain identifier, so any
        // segment that lexed as a keyword or preposition was a parse error
        // wherever the name appeared: `<content-type>`, `<with-tax>`,
        // `<tax-with>`, `<from-date>`, `<by-age>`, `{ created-at: … }`,
        // `<request: headers.Content-Type>` (GitLab #579, #583). Meanwhile
        // `taxed-price` and `user-email-address` were fine, so the rule was
        // not discoverable by trying a few names.
        //
        // Nothing is ambiguous here. **After a hyphen** no clause can begin —
        // only the rest of the name — so any word is taken verbatim. That is
        // what makes `created-at`, `valid-from` and `Content-Type` reachable,
        // and the header case has no workaround by renaming: the name is
        // chosen by whoever produced the data.
        var result = try parseNameSegment(isFirst: true, message: "identifier").lexeme

        while check(.hyphen) {
            advance()
            result += "-"
            result += try parseNameSegment(isFirst: false, message: "identifier after '-'").lexeme
        }

        return result
    }

    /// One segment of a possibly-hyphenated name.
    ///
    /// After a hyphen, every word-shaped token is accepted — a keyword there
    /// is part of the name, not the start of a clause.
    ///
    /// For the **first** segment a reserved word is accepted only when a
    /// hyphen follows it, which is the one token of lookahead that tells
    /// `<with-tax>` (a name) from `with` (a preposition opening a clause). So
    /// `with` alone still lexes and parses exactly as it did.
    private func parseNameSegment(isFirst: Bool, message: String) throws -> Token {
        if !isFirst, peek().isWordShaped {
            return advance()
        }
        if isFirst, peek().isWordShaped, peekAt(1)?.kind == .hyphen {
            return advance()
        }
        return try expectIdentifier(message: message)
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

    /// Safe lookahead by offset from current position.
    /// Returns nil if out of bounds instead of requiring manual bounds checking.
    private func peekAt(_ offset: Int) -> Token? {
        let index = current + offset
        guard index >= 0 && index < tokens.count else { return nil }
        return tokens[index]
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

    /// Consumes the statement-terminating dot, tolerating a run of
    /// extra dots (`..`, `...`) — typically a double-tapped `.`
    /// keystroke (#372). The intent is unambiguous (one terminator,
    /// stray keys), so no diagnostic surfaces; the SOLARO
    /// reformatter normalises the source on the next Reformat Code
    /// (`AROFormatter.collapseTrailingDots`). Returns the last dot
    /// token, so callers that fold the terminator into their span
    /// (Publish, Require, pipelines) absorb the whole run. Nothing
    /// else in the grammar begins a statement with `.`, so the
    /// greedy consume can't swallow a meaningful token.
    @discardableResult
    private func expectStatementTerminator() throws -> Token {
        var endToken = try expect(.dot, message: "'.'")
        while check(.dot) {
            endToken = advance()
        }
        return endToken
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
        // GitLab #548: `empty` is only a keyword after `is` (`<list> is empty`,
        // handled before any type name is expected), so it stays a usable name:
        // `<empty>`, `{ empty: 0 }` and `<x: empty>` are ordinary identifiers.
        switch token.kind {
        case .when, .then, .exists, .empty:
            return advance()
        default:
            break
        }
        throw ParserError.unexpectedToken(expected: message, got: token)
    }

    /// Expects a specific preposition token and advances, or throws a consistent error.
    @discardableResult
    private func expectPreposition(_ expected: Preposition, message: String) throws -> Token {
        if case .preposition(let p) = peek().kind, p == expected {
            return advance()
        }
        throw ParserError.unexpectedToken(expected: message, got: peek())
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
        _ = synchronizeToNextStatementCollecting()
    }

    /// Synchronizes to the next statement after an error, returning the skipped tokens.
    /// Used to populate `ErrorStatement.skippedTokens` for partial AST construction.
    @discardableResult
    private func synchronizeToNextStatementCollecting() -> [Token] {
        var skipped: [Token] = []

        // Always advance at least once to make progress and avoid infinite loops
        // when we're already positioned after a statement-ending dot
        if !isAtEnd {
            skipped.append(advance())
        }

        while !isAtEnd {
            // If we just passed a dot, we're at the start of a new statement
            if previous().kind == .dot {
                return skipped
            }

            // If we see a closing brace, stop
            if check(.rightBrace) {
                return skipped
            }

            // If we see an opening angle bracket, we might be at a new statement
            if check(.leftAngle) {
                return skipped
            }

            skipped.append(advance())
        }

        return skipped
    }
}

// MARK: - Expression Parsing (ARO-0002)

/// Operator precedence levels for Pratt parsing.
///
/// The order is the one spelled out in ARO-0001 § Operator Precedence and it
/// is the one every mainstream language uses: arithmetic binds tightest,
/// then comparisons, then `not`, then `and`, then `or` (GitLab #520). Reading
/// a rule aloud — "the order is at least fifteen, or the customer is a VIP" —
/// must group the way the parser groups it.
///
/// `not` deliberately sits *below* the comparisons (as in Python, not C):
/// `not <a> == <b>` is `not (<a> == <b>)`. Unary minus is the exception —
/// it stays at `.unary`, above `*`, so `-<a> * <b>` is `(-<a>) * <b>`.
///
/// `default` (GitLab #547) sits between arithmetic and comparison, so
/// `<a> default 1 + 2` defaults to the whole sum and `<a> default 3 > 2`
/// compares the defaulted value instead of defaulting to a boolean.
private enum Precedence: Int, Comparable {
    case none = 0
    case or = 1           // or
    case and = 2          // and
    case not = 3          // not (prefix)
    case equality = 4     // == != is is_not contains matches
    case comparison = 5   // < > <= >=
    case defaulting = 6   // default (GitLab #547)
    case term = 7         // + - ++
    case factor = 8       // * / %
    case unary = 9        // unary -
    case postfix = 10     // . []

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
            return try parseArrayLiteralExpression()

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
        // Binds looser than the comparisons, so `not <a> == <b>` negates the
        // comparison instead of comparing a negated `<a>` (GitLab #520), and
        // still stops before `and`/`or`: `not <a> and <b>` is `(not <a>) and <b>`.
        case .not:
            advance()
            let operand = try parsePrecedence(.not)
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
            var base = name
            var span = token.span
            // Join immediately-adjacent `-identifier` pairs into a compound
            // identifier, matching every other ARO context (nouns, object
            // keys, feature names): `${custom-header}` resolves the
            // hyphenated variable. Whitespace keeps subtraction: `${a - b}`.
            // Adjacency is byte-exact — a token's span ends where the next
            // one starts only when nothing separates them.
            while case .hyphen = peek().kind,
                  current + 1 < tokens.count,
                  case .identifier(let nextName) = tokens[current + 1].kind,
                  span.end.byteOffset == peek().span.start.byteOffset,
                  peek().span.end.byteOffset == tokens[current + 1].span.start.byteOffset {
                advance() // hyphen
                let nextToken = advance()
                base += "-" + nextName
                span = span.merged(with: nextToken.span)
            }
            // Create a QualifiedNoun for the identifier
            let noun = QualifiedNoun(base: base, typeAnnotation: nil, span: span)
            return VariableRefExpression(noun: noun, span: span)

        default:
            throw ParserError.unexpectedToken(expected: "expression", got: token)
        }
    }

    // MARK: - Infix Parsing

    /// Gets the precedence of an infix operator
    /// Binary-operator precedence as **data**, not control flow (issue #348).
    /// This table is the single source of truth for how tightly each operator
    /// binds — adding or retuning an operator means editing one line here rather
    /// than tracing parse methods. Token kinds are mapped to operators by
    /// `binaryOperator(from:)`; the context-sensitive tokens (`<`/`>` as
    /// comparison vs. `<variable>` reference, `.` as member access vs. statement
    /// terminator, `[` as subscript) still need lookahead and stay in
    /// `infixPrecedence` below.
    private static let binaryPrecedence: [BinaryOperator: Precedence] = [
        .or:           .or,
        .and:          .and,
        .defaulting:   .defaulting,
        .equal:        .equality,
        .notEqual:     .equality,
        .is:           .equality,
        .isNot:        .equality,
        .contains:     .equality,
        // Membership and affix tests read as comparisons (GitLab #830
        // item 5, GitLab #864), so `when <p> starts with "/" and <m> is "GET"`
        // groups the way it reads.
        .subset:       .equality,
        .notIn:        .equality,
        .startsWith:   .equality,
        .endsWith:     .equality,
        // Temporal comparison sits with the other comparisons, so
        // `when <a> before <b> and <c> after <d>` groups the way it
        // reads (GitLab #516).
        .matches:      .equality,
        .lessThan:     .comparison,
        .greaterThan:  .comparison,
        .lessEqual:    .comparison,
        .greaterEqual: .comparison,
        .add:          .term,
        .subtract:     .term,
        .concat:       .term,
        .multiply:     .factor,
        .divide:       .factor,
        .modulo:       .factor,
    ]

    private func infixPrecedence(_ token: Token) -> Precedence? {
        switch token.kind {
        // Context-sensitive: `before` / `after` are temporal comparisons
        // in operator position and ordinary names everywhere else
        // (GitLab #516). They are NOT lexer keywords, deliberately —
        // `<after>`, `<before-tax>` are names people write, and
        // reserving the words would break them the way #497 describes.
        // Nothing else can follow a complete expression here, so the
        // position tells them apart with no lookahead.
        case .identifier(let name) where name == "before" || name == "after":
            return .comparison

        // `subset` is a set-containment predicate in operator position and an
        // ordinary name everywhere else (GitLab #864) — the same
        // context-sensitive treatment `before` and `after` get, and for the
        // same reason: `<subset>` is a name people write.
        case .identifier(let name) where name == "subset":
            return .equality

        // `in` is a membership comparison in operator position. It is a
        // lexer keyword because `for each <x> in <xs>` needs it, but every
        // place that uses it as a delimiter consumes it with `expect(.in)`
        // before any expression parsing starts, so giving it a precedence
        // here cannot swallow one of those (GitLab #558).
        case .in:
            return .comparison

        // `starts with` / `ends with` — context-sensitive for the same
        // reason `before`/`after` are: `<starts>` and `<ends>` are
        // ordinary names, so neither word is a lexer keyword. Only a
        // following `with` makes it an operator, which is the lookahead
        // this case performs (GitLab #830 item 5).
        case .identifier(let name) where name.lowercased() == "starts"
                                      || name.lowercased() == "ends":
            let nextIndex = current + 1
            guard nextIndex < tokens.count,
                  case .preposition(.with) = tokens[nextIndex].kind else { return nil }
            return .comparison

        // `not in`: `not` alone is the unary negation and must stay one,
        // so only the pair is an infix operator.
        case .not:
            let nextIndex = current + 1
            guard nextIndex < tokens.count,
                  case .in = tokens[nextIndex].kind else { return nil }
            return .comparison

        // Context-sensitive: `<` / `>` are comparison operators here only when
        // they are not starting a `<variable>` reference.
        case .leftAngle, .rightAngle:
            let nextIndex = current + 1
            if nextIndex < tokens.count, case .identifier = tokens[nextIndex].kind {
                // Could be starting a variable ref — don't treat as comparison.
                return nil
            }
            return .comparison

        // Context-sensitive: `.` is member access only before a lowercase
        // identifier; otherwise it's a statement terminator (capitalized
        // identifiers are action verbs like Log/Return that start new statements).
        case .dot:
            let nextIndex = current + 1
            if nextIndex < tokens.count,
               case .identifier(let name) = tokens[nextIndex].kind,
               let first = name.first, first.isLowercase {
                return .postfix
            }
            return nil

        // Subscript.
        case .leftBracket:
            return .postfix

        // Context-sensitive: `default` is a value-returning fallback operator
        // (GitLab #547), not a reserved word — a variable or field may still be
        // called `default`. It is suppressed inside a where-condition, where
        // `default` is the query modifier of ARO-0018 (`Extract … where <id> is
        // 5 default "none".`), so the statement-level clause keeps its meaning.
        case .identifier(let name) where name == "default":
            return defaultOperatorSuppressed ? nil : .defaulting

        // Every other binary operator: precedence comes from the table.
        default:
            return binaryOperator(from: token.kind).flatMap { Self.binaryPrecedence[$0] }
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

            // `subset of <b>` — the `of` is part of the operator and reads
            // like English (GitLab #864). It is optional so that `<a> subset
            // <b>` is not a parse error for something whose meaning is plain;
            // ARO-0042 writes the `of`.
            if actualOp == .subset, case .identifier("of") = peek().kind {
                advance()
            }

            // The other two-word operators (GitLab #830 item 5).
            // `infixPrecedence` already refused to reach here unless the
            // second word is present, so these consume it unconditionally.
            if op == .startsWith || op == .endsWith {
                try expectPreposition(.with, message: "'with' after '\(token.lexeme)'")
            }
            if op == .notIn {
                try expect(.in, message: "'in' after 'not'")
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

                // `is empty` / `is not empty` (ARO-0002, GitLab #463).
                // Must come before the type-name path: `empty` is its
                // own keyword token, so `expectIdentifier` rejected it
                // with "Expected type name, but got empty" — the
                // documented spelling of a very common guard didn't
                // parse at all.
                if check(.empty) {
                    let emptyToken = advance()
                    let span = left.span.merged(with: emptyToken.span)
                    return EmptinessCheckExpression(
                        expression: left,
                        negated: actualOp == .isNot,
                        span: span)
                }

                // Everything that is not a type name compares for
                // equality: `is "paid"`, `is 5`, `is <expected>` are the
                // spellings Filter's where-clause has always accepted, and
                // loop where-clauses share this grammar (GitLab #500 —
                // strings after `is` used to die on 'Expected type name').
                // A bare identifier (with optional article) stays a type
                // check: `is Float`, `is a String`.
                switch peek().kind {
                case .identifier, .article:
                    break // type-check path below
                default:
                    let right = try parsePrefix()
                    let span = left.span.merged(with: right.span)
                    let compOp: BinaryOperator = (actualOp == .isNot) ? .notEqual : .equal
                    return BinaryExpression(left: left, op: compOp, right: right, span: span)
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

            // Parse right operand with higher precedence (left-associative).
            //
            // `and`/`or` used to rewrite their operands here: when the left
            // side was a comparison and the right side was a bare value, the
            // parser distributed the comparison's subject and operator across
            // the connective, so `<x> == "a" or "b"` became
            // `<x> == "a" or <x> == "b"`. That shorthand was never in
            // ARO-0001, and it made precedence depend on the *shape* of the
            // operands rather than on the operators — so
            // `<n> >= 15 or <vip>` silently became `<n> >= 15 or <n> >= <vip>`
            // and died on "Cannot convert Bool to number" (GitLab #520),
            // while the same rule with `and` between two comparisons parsed
            // fine. It had already produced a silent wrong *result* once
            // (the crawler's `contains … and (…)`, patched by excluding
            // grouped right-hand sides). The rewrite is gone: precedence is
            // now exactly the table in ARO-0001, and nothing about an
            // operand's shape can change the grouping.
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
        case .equalEqual, .equals: return .equal
        case .bangEqual: return .notEqual
        case .lessThan, .leftAngle: return .lessThan
        case .greaterThan, .rightAngle: return .greaterThan
        case .lessEqual: return .lessEqual
        case .greaterEqual: return .greaterEqual
        case .is: return .is
        case .identifier(let name) where name == "before": return .before
        case .identifier(let name) where name == "after": return .after
        case .identifier(let name) where name == "subset": return .subset
        case .identifier(let name) where name.lowercased() == "starts": return .startsWith
        case .identifier(let name) where name.lowercased() == "ends": return .endsWith
        case .in: return .in
        case .not: return .notIn
        case .and: return .and
        case .or: return .or
        case .identifier("default"): return .defaulting
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

    /// Parses an array literal of expressions: [elem1, elem2, ...]
    private func parseArrayLiteralExpression() throws -> ArrayLiteralExpression {
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
            key = try parseHyphenatedKey(startingWith: s)
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
        // Parentheses end the where-clause ambiguity: inside them a `default`
        // can only be the operator, so it is available again (GitLab #547).
        let previouslySuppressed = defaultOperatorSuppressed
        defaultOperatorSuppressed = false
        defer { defaultOperatorSuppressed = previouslySuppressed }
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
    /// Parses source, reporting recovery errors to `diagnostics`.
    ///
    /// The parser recovers: a feature set it cannot read is reported
    /// and skipped, and parsing continues. The returned `Program`
    /// therefore holds what *did* parse — possibly nothing — and the
    /// collector holds why. Callers on this overload must read the
    /// collector; the CLI does exactly that, which is how `aro check`
    /// reports several errors in one pass.
    public static func parse(_ source: String,
                             diagnostics: DiagnosticCollector) throws -> Program {
        let tokens = try Lexer.tokenize(source, diagnostics: diagnostics)
        return try Parser(tokens: tokens, diagnostics: diagnostics).parse()
    }

    /// Parses source, throwing if anything failed to parse.
    ///
    /// Without a collector there is nowhere for recovery errors to
    /// go, and a caller could not tell "this file has no feature
    /// sets" from "this file did not parse" — a `Program` with zero
    /// feature sets means both. That ambiguity is what made a graph
    /// diff over an unchanged tree report 144 feature sets rewritten
    /// (GitLab #543): every broken file read as empty.
    ///
    /// So this overload is strict. Recovery still happens internally
    /// — the thrown `ParserError.recovered` carries every diagnostic,
    /// not just the first — but an unread failure cannot pass for an
    /// empty file. Pass a collector when you want the recovering
    /// contract.
    public static func parse(_ source: String) throws -> Program {
        let diagnostics = DiagnosticCollector()
        let program = try parse(source, diagnostics: diagnostics)
        let errors = diagnostics.diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            throw ParserError.recovered(errors: errors)
        }
        return program
    }
}
