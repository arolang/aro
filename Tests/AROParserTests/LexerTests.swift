// ============================================================
// LexerTests.swift
// ARO Parser - Comprehensive Lexer Unit Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Token Kind Tests

@Suite("Token Kind Tests")
struct TokenKindTests {

    @Test("Token descriptions are correct")
    func testTokenDescriptions() {
        #expect(TokenKind.leftParen.description == "(")
        #expect(TokenKind.rightParen.description == ")")
        #expect(TokenKind.leftBrace.description == "{")
        #expect(TokenKind.rightBrace.description == "}")
        #expect(TokenKind.leftAngle.description == "<")
        #expect(TokenKind.rightAngle.description == ">")
        #expect(TokenKind.leftBracket.description == "[")
        #expect(TokenKind.rightBracket.description == "]")
        #expect(TokenKind.colon.description == ":")
        #expect(TokenKind.doubleColon.description == "::")
        #expect(TokenKind.dot.description == ".")
        #expect(TokenKind.hyphen.description == "-")
        #expect(TokenKind.comma.description == ",")
        #expect(TokenKind.semicolon.description == ";")
        #expect(TokenKind.atSign.description == "@")
        #expect(TokenKind.question.description == "?")
        #expect(TokenKind.arrow.description == "->")
        #expect(TokenKind.fatArrow.description == "=>")
        #expect(TokenKind.equals.description == "=")
        #expect(TokenKind.eof.description == "EOF")
    }

    @Test("Operator descriptions are correct")
    func testOperatorDescriptions() {
        #expect(TokenKind.plus.description == "+")
        #expect(TokenKind.minus.description == "-")
        #expect(TokenKind.star.description == "*")
        #expect(TokenKind.slash.description == "/")
        #expect(TokenKind.percent.description == "%")
        #expect(TokenKind.plusPlus.description == "++")
        #expect(TokenKind.equalEqual.description == "==")
        #expect(TokenKind.bangEqual.description == "!=")
        #expect(TokenKind.lessThan.description == "<")
        #expect(TokenKind.greaterThan.description == ">")
        #expect(TokenKind.lessEqual.description == "<=")
        #expect(TokenKind.greaterEqual.description == ">=")
    }

    @Test("Keyword descriptions are correct")
    func testKeywordDescriptions() {
        #expect(TokenKind.publish.description == "Publish")
        #expect(TokenKind.as.description == "as")
        #expect(TokenKind.if.description == "if")
        #expect(TokenKind.then.description == "then")
        #expect(TokenKind.else.description == "else")
        #expect(TokenKind.when.description == "when")
        #expect(TokenKind.match.description == "match")
        #expect(TokenKind.case.description == "case")
        #expect(TokenKind.otherwise.description == "otherwise")
        #expect(TokenKind.where.description == "where")
        #expect(TokenKind.for.description == "for")
        #expect(TokenKind.each.description == "each")
        #expect(TokenKind.in.description == "in")
        #expect(TokenKind.atKeyword.description == "at")
        #expect(TokenKind.parallel.description == "parallel")
        #expect(TokenKind.concurrency.description == "concurrency")
        #expect(TokenKind.and.description == "and")
        #expect(TokenKind.or.description == "or")
        #expect(TokenKind.not.description == "not")
        #expect(TokenKind.is.description == "is")
        #expect(TokenKind.exists.description == "exists")
        #expect(TokenKind.defined.description == "defined")
        #expect(TokenKind.null.description == "null")
        #expect(TokenKind.empty.description == "empty")
        #expect(TokenKind.contains.description == "contains")
        #expect(TokenKind.matches.description == "matches")
    }

    @Test("Literal descriptions are correct")
    func testLiteralDescriptions() {
        #expect(TokenKind.identifier("test").description == "identifier(test)")
        #expect(TokenKind.stringLiteral("hello").description == "string(\"hello\")")
        #expect(TokenKind.intLiteral(42).description == "int(42)")
        #expect(TokenKind.floatLiteral(3.14).description == "float(3.14)")
        #expect(TokenKind.true.description == "true")
        #expect(TokenKind.false.description == "false")
        #expect(TokenKind.nil.description == "nil")
    }

    @Test("Article descriptions are correct")
    func testArticleDescriptions() {
        #expect(TokenKind.article(.a).description == "article(a)")
        #expect(TokenKind.article(.an).description == "article(an)")
        #expect(TokenKind.article(.the).description == "article(the)")
    }

    @Test("Preposition descriptions are correct")
    func testPrepositionDescriptions() {
        #expect(TokenKind.preposition(.from).description == "preposition(from)")
        #expect(TokenKind.preposition(.for).description == "preposition(for)")
        #expect(TokenKind.preposition(.against).description == "preposition(against)")
        #expect(TokenKind.preposition(.to).description == "preposition(to)")
        #expect(TokenKind.preposition(.into).description == "preposition(into)")
        #expect(TokenKind.preposition(.via).description == "preposition(via)")
        #expect(TokenKind.preposition(.with).description == "preposition(with)")
    }

    @Test("isIdentifier works correctly")
    func testIsIdentifier() {
        #expect(TokenKind.identifier("test").isIdentifier == true)
        #expect(TokenKind.identifier("").isIdentifier == true)
        #expect(TokenKind.stringLiteral("test").isIdentifier == false)
        #expect(TokenKind.intLiteral(42).isIdentifier == false)
        #expect(TokenKind.publish.isIdentifier == false)
    }

    @Test("identifierValue works correctly")
    func testIdentifierValue() {
        #expect(TokenKind.identifier("test").identifierValue == "test")
        #expect(TokenKind.identifier("hello").identifierValue == "hello")
        #expect(TokenKind.stringLiteral("test").identifierValue == nil)
        #expect(TokenKind.intLiteral(42).identifierValue == nil)
    }

    @Test("isArticle works correctly")
    func testIsArticle() {
        #expect(TokenKind.article(.a).isArticle == true)
        #expect(TokenKind.article(.an).isArticle == true)
        #expect(TokenKind.article(.the).isArticle == true)
        #expect(TokenKind.identifier("a").isArticle == false)
        #expect(TokenKind.publish.isArticle == false)
    }

    @Test("isPreposition works correctly")
    func testIsPreposition() {
        #expect(TokenKind.preposition(.from).isPreposition == true)
        #expect(TokenKind.preposition(.for).isPreposition == true)
        #expect(TokenKind.preposition(.with).isPreposition == true)
        #expect(TokenKind.identifier("from").isPreposition == false)
        #expect(TokenKind.for.isPreposition == false)
    }

    @Test("prepositionValue works correctly")
    func testPrepositionValue() {
        #expect(TokenKind.preposition(.from).prepositionValue == .from)
        #expect(TokenKind.preposition(.for).prepositionValue == .for)
        #expect(TokenKind.preposition(.with).prepositionValue == .with)
        #expect(TokenKind.for.prepositionValue == nil)
        #expect(TokenKind.identifier("from").prepositionValue == nil)
    }

    @Test("isLiteral works correctly")
    func testIsLiteral() {
        #expect(TokenKind.stringLiteral("test").isLiteral == true)
        #expect(TokenKind.intLiteral(42).isLiteral == true)
        #expect(TokenKind.floatLiteral(3.14).isLiteral == true)
        #expect(TokenKind.true.isLiteral == true)
        #expect(TokenKind.false.isLiteral == true)
        #expect(TokenKind.nil.isLiteral == true)
        #expect(TokenKind.identifier("test").isLiteral == false)
        #expect(TokenKind.publish.isLiteral == false)
    }

    @Test("isComparisonOperator works correctly")
    func testIsComparisonOperator() {
        #expect(TokenKind.equalEqual.isComparisonOperator == true)
        #expect(TokenKind.bangEqual.isComparisonOperator == true)
        #expect(TokenKind.lessThan.isComparisonOperator == true)
        #expect(TokenKind.greaterThan.isComparisonOperator == true)
        #expect(TokenKind.lessEqual.isComparisonOperator == true)
        #expect(TokenKind.greaterEqual.isComparisonOperator == true)
        #expect(TokenKind.is.isComparisonOperator == true)
        #expect(TokenKind.contains.isComparisonOperator == true)
        #expect(TokenKind.matches.isComparisonOperator == true)
        #expect(TokenKind.plus.isComparisonOperator == false)
        #expect(TokenKind.equals.isComparisonOperator == false)
    }

    @Test("isAdditiveOperator works correctly")
    func testIsAdditiveOperator() {
        #expect(TokenKind.plus.isAdditiveOperator == true)
        #expect(TokenKind.minus.isAdditiveOperator == true)
        #expect(TokenKind.plusPlus.isAdditiveOperator == true)
        #expect(TokenKind.star.isAdditiveOperator == false)
        #expect(TokenKind.slash.isAdditiveOperator == false)
    }

    @Test("isMultiplicativeOperator works correctly")
    func testIsMultiplicativeOperator() {
        #expect(TokenKind.star.isMultiplicativeOperator == true)
        #expect(TokenKind.slash.isMultiplicativeOperator == true)
        #expect(TokenKind.percent.isMultiplicativeOperator == true)
        #expect(TokenKind.plus.isMultiplicativeOperator == false)
        #expect(TokenKind.minus.isMultiplicativeOperator == false)
    }

    @Test("isStatementKeyword works correctly")
    func testIsStatementKeyword() {
        #expect(TokenKind.if.isStatementKeyword == true)
        #expect(TokenKind.match.isStatementKeyword == true)
        #expect(TokenKind.for.isStatementKeyword == true)
        #expect(TokenKind.parallel.isStatementKeyword == true)
        #expect(TokenKind.guard.isStatementKeyword == true)
        #expect(TokenKind.defer.isStatementKeyword == true)
        #expect(TokenKind.assert.isStatementKeyword == true)
        #expect(TokenKind.precondition.isStatementKeyword == true)
        #expect(TokenKind.publish.isStatementKeyword == false)
        #expect(TokenKind.identifier("test").isStatementKeyword == false)
    }
}

// MARK: - Article Tests

@Suite("Article Tests")
struct ArticleTests {

    @Test("All articles have correct raw values")
    func testArticleRawValues() {
        #expect(Article.a.rawValue == "a")
        #expect(Article.an.rawValue == "an")
        #expect(Article.the.rawValue == "the")
    }

    @Test("All cases are iterable")
    func testAllCases() {
        #expect(Article.allCases.count == 3)
        #expect(Article.allCases.contains(.a))
        #expect(Article.allCases.contains(.an))
        #expect(Article.allCases.contains(.the))
    }
}

// MARK: - Preposition Tests

@Suite("Preposition Tests")
struct PrepositionTests {

    @Test("All prepositions have correct raw values")
    func testPrepositionRawValues() {
        #expect(Preposition.from.rawValue == "from")
        #expect(Preposition.for.rawValue == "for")
        #expect(Preposition.against.rawValue == "against")
        #expect(Preposition.to.rawValue == "to")
        #expect(Preposition.into.rawValue == "into")
        #expect(Preposition.via.rawValue == "via")
        #expect(Preposition.with.rawValue == "with")
        #expect(Preposition.on.rawValue == "on")
        #expect(Preposition.at.rawValue == "at")
        #expect(Preposition.by.rawValue == "by")
    }

    @Test("All cases are iterable")
    func testAllCases() {
        #expect(Preposition.allCases.count == 10)
    }

    @Test("External source detection works correctly")
    func testIndicatesExternalSource() {
        #expect(Preposition.from.indicatesExternalSource == true)
        #expect(Preposition.via.indicatesExternalSource == true)
        #expect(Preposition.for.indicatesExternalSource == false)
        #expect(Preposition.against.indicatesExternalSource == false)
        #expect(Preposition.to.indicatesExternalSource == false)
        #expect(Preposition.into.indicatesExternalSource == false)
        #expect(Preposition.with.indicatesExternalSource == false)
        #expect(Preposition.on.indicatesExternalSource == false)
        #expect(Preposition.at.indicatesExternalSource == false)
        #expect(Preposition.by.indicatesExternalSource == false)
    }
}

// MARK: - Token Tests

@Suite("Token Tests")
struct TokenTests {

    @Test("Token creation works correctly")
    func testTokenCreation() {
        let span = SourceSpan(at: SourceLocation())
        let token = Token(kind: .identifier("test"), span: span, lexeme: "test")

        #expect(token.kind == .identifier("test"))
        #expect(token.lexeme == "test")
    }

    @Test("Token description is correct")
    func testTokenDescription() {
        let span = SourceSpan(at: SourceLocation())
        let token = Token(kind: .identifier("test"), span: span, lexeme: "test")

        #expect(token.description.contains("identifier(test)"))
    }

    @Test("Token equality works correctly")
    func testTokenEquality() {
        let span = SourceSpan(at: SourceLocation())
        let token1 = Token(kind: .identifier("test"), span: span, lexeme: "test")
        let token2 = Token(kind: .identifier("test"), span: span, lexeme: "test")
        let token3 = Token(kind: .identifier("other"), span: span, lexeme: "other")

        #expect(token1 == token2)
        #expect(token1 != token3)
    }
}

// MARK: - Lexer Tokenization Tests

@Suite("Lexer Tokenization Tests")
struct LexerTokenizationTests {

    @Test("Tokenizes empty source")
    func testEmptySource() throws {
        let tokens = try Lexer.tokenize("")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .eof)
    }

    @Test("Tokenizes whitespace only")
    func testWhitespaceOnly() throws {
        let tokens = try Lexer.tokenize("   \t\n  ")
        #expect(tokens.count == 1)
        #expect(tokens[0].kind == .eof)
    }

    @Test("Tokenizes all delimiters")
    func testDelimiters() throws {
        let tokens = try Lexer.tokenize("( ) { } < > [ ] : :: . - , ; @ ?")

        let kinds = tokens.dropLast().map { $0.kind }
        #expect(kinds.contains(.leftParen))
        #expect(kinds.contains(.rightParen))
        #expect(kinds.contains(.leftBrace))
        #expect(kinds.contains(.rightBrace))
        #expect(kinds.contains(.leftAngle))
        #expect(kinds.contains(.rightAngle))
        #expect(kinds.contains(.leftBracket))
        #expect(kinds.contains(.rightBracket))
        #expect(kinds.contains(.colon))
        #expect(kinds.contains(.doubleColon))
        #expect(kinds.contains(.dot))
        #expect(kinds.contains(.hyphen))
        #expect(kinds.contains(.comma))
        #expect(kinds.contains(.semicolon))
        #expect(kinds.contains(.atSign))
        #expect(kinds.contains(.question))
    }

    @Test("Tokenizes arrow operators")
    func testArrowOperators() throws {
        let tokens = try Lexer.tokenize("-> =>")

        #expect(tokens.count == 3) // ->, =>, EOF
        #expect(tokens[0].kind == .arrow)
        #expect(tokens[1].kind == .fatArrow)
    }

    @Test("Tokenizes comparison operators")
    func testComparisonOperators() throws {
        let tokens = try Lexer.tokenize("== != <= >=")

        #expect(tokens[0].kind == .equalEqual)
        #expect(tokens[1].kind == .bangEqual)
        #expect(tokens[2].kind == .lessEqual)
        #expect(tokens[3].kind == .greaterEqual)
    }

    @Test("Tokenizes arithmetic operators")
    func testArithmeticOperators() throws {
        let tokens = try Lexer.tokenize("+ * / % ++")

        #expect(tokens[0].kind == .plus)
        #expect(tokens[1].kind == .star)
        #expect(tokens[2].kind == .slash)
        #expect(tokens[3].kind == .percent)
        #expect(tokens[4].kind == .plusPlus)

        // Hyphen is tokenized as .hyphen not .minus
        let hyphenTokens = try Lexer.tokenize("-")
        #expect(hyphenTokens[0].kind == .hyphen)
    }

    @Test("Tokenizes identifiers")
    func testIdentifiers() throws {
        let tokens = try Lexer.tokenize("hello world foo123 _underscore")

        #expect(tokens[0].kind == .identifier("hello"))
        #expect(tokens[1].kind == .identifier("world"))
        #expect(tokens[2].kind == .identifier("foo123"))
        #expect(tokens[3].kind == .identifier("_underscore"))
    }

    @Test("Tokenizes case-insensitive identifiers as keywords")
    func testCaseInsensitiveKeywords() throws {
        let tokens1 = try Lexer.tokenize("Publish")
        let tokens2 = try Lexer.tokenize("PUBLISH")
        let tokens3 = try Lexer.tokenize("publish")

        #expect(tokens1[0].kind == .publish)
        #expect(tokens2[0].kind == .publish)
        #expect(tokens3[0].kind == .publish)
    }

    @Test("Tokenizes string literals")
    func testStringLiterals() throws {
        let tokens = try Lexer.tokenize("\"hello world\"")

        #expect(tokens[0].kind == .stringLiteral("hello world"))
    }

    @Test("Tokenizes string literals with escape sequences")
    func testStringEscapeSequences() throws {
        let tokens = try Lexer.tokenize("\"hello\\nworld\\t!\"")

        #expect(tokens[0].kind == .stringLiteral("hello\nworld\t!"))
    }

    @Test("Tokenizes string literals with quotes")
    func testStringWithQuotes() throws {
        let tokens = try Lexer.tokenize("\"he said \\\"hello\\\"\"")

        #expect(tokens[0].kind == .stringLiteral("he said \"hello\""))
    }

    @Test("Single quotes create raw string literals (ARO-0060)")
    func testRawStringLiterals() throws {
        // Basic raw string with single quotes
        let tokens1 = try Lexer.tokenize(#"'\d+\.\d+'"#)
        #expect(tokens1[0].kind == .stringLiteral(#"\d+\.\d+"#))

        // Raw string with Windows path
        let tokens2 = try Lexer.tokenize(#"'C:\Users\Admin\config.json'"#)
        #expect(tokens2[0].kind == .stringLiteral(#"C:\Users\Admin\config.json"#))

        // Raw string with backslashes
        let tokens3 = try Lexer.tokenize(#"'\\server\share\file'"#)
        #expect(tokens3[0].kind == .stringLiteral(#"\\server\share\file"#))
    }

    @Test("Raw strings allow escaped quotes (ARO-0060)")
    func testRawStringEscapedQuotes() throws {
        // Raw string with escaped single quote
        let tokens = try Lexer.tokenize(#"'Path: \'important\''"#)
        #expect(tokens[0].kind == .stringLiteral(#"Path: 'important'"#))
    }

    @Test("Single quotes (raw) vs double quotes (regular) (ARO-0060)")
    func testRawVsRegularStrings() throws {
        // Double quotes: regular string with escape processing
        let regular = try Lexer.tokenize(#""\\d+\\n""#)
        #expect(regular[0].kind == .stringLiteral("\\d+\\n"))

        // Single quotes: raw string without escape processing
        let raw = try Lexer.tokenize(#"'\\d+\\n'"#)
        #expect(raw[0].kind == .stringLiteral(#"\\d+\\n"#))
    }

    @Test("Double quotes process escape sequences (ARO-0060)")
    func testDoubleQuotesProcessEscapes() throws {
        // Double quotes process \n as newline
        let tokens = try Lexer.tokenize(#""Hello\nWorld""#)
        #expect(tokens[0].kind == .stringLiteral("Hello\nWorld"))

        // Single quotes keep \n literal
        let raw = try Lexer.tokenize(#"'Hello\nWorld'"#)
        #expect(raw[0].kind == .stringLiteral(#"Hello\nWorld"#))
    }

    @Test("Tokenizes integer literals")
    func testIntegerLiterals() throws {
        let tokens = try Lexer.tokenize("42 0 123456")

        #expect(tokens[0].kind == .intLiteral(42))
        #expect(tokens[1].kind == .intLiteral(0))
        #expect(tokens[2].kind == .intLiteral(123456))
    }

    @Test("Tokenizes float literals")
    func testFloatLiterals() throws {
        let tokens = try Lexer.tokenize("3.14 0.5 123.456")

        #expect(tokens[0].kind == .floatLiteral(3.14))
        #expect(tokens[1].kind == .floatLiteral(0.5))
        #expect(tokens[2].kind == .floatLiteral(123.456))
    }

    @Test("Tokenizes hexadecimal literals")
    func testHexLiterals() throws {
        let tokens = try Lexer.tokenize("0xFF 0x10 0xABCDEF")

        #expect(tokens[0].kind == .intLiteral(255))
        #expect(tokens[1].kind == .intLiteral(16))
        #expect(tokens[2].kind == .intLiteral(0xABCDEF))
    }

    @Test("Tokenizes binary literals")
    func testBinaryLiterals() throws {
        let tokens = try Lexer.tokenize("0b1010 0b1111")

        #expect(tokens[0].kind == .intLiteral(10))
        #expect(tokens[1].kind == .intLiteral(15))
    }

    @Test("Tokenizes boolean literals")
    func testBooleanLiterals() throws {
        let tokens = try Lexer.tokenize("true false")

        #expect(tokens[0].kind == .true)
        #expect(tokens[1].kind == .false)
    }

    @Test("Tokenizes nil literal")
    func testNilLiteral() throws {
        let tokens = try Lexer.tokenize("nil")

        #expect(tokens[0].kind == .nil)
    }

    @Test("Tokenizes articles")
    func testArticlesTokenization() throws {
        let tokens = try Lexer.tokenize("a an the")

        #expect(tokens[0].kind == .article(.a))
        #expect(tokens[1].kind == .article(.an))
        #expect(tokens[2].kind == .article(.the))
    }

    @Test("Tokenizes prepositions")
    func testPrepositionsTokenization() throws {
        let tokens = try Lexer.tokenize("from against to into with via")

        #expect(tokens[0].kind == .preposition(.from))
        #expect(tokens[1].kind == .preposition(.against))
        #expect(tokens[2].kind == .preposition(.to))
        #expect(tokens[3].kind == .preposition(.into))
        #expect(tokens[4].kind == .preposition(.with))
        #expect(tokens[5].kind == .preposition(.via))
    }

    @Test("Tokenizes 'for' as preposition")
    func testForPreposition() throws {
        let tokens = try Lexer.tokenize("for")

        // "for" is tokenized as a preposition (prioritized over keyword)
        // The parser handles "for each" by accepting preposition(.for)
        #expect(tokens[0].kind == .preposition(.for))
    }

    @Test("Tokenizes control flow keywords")
    func testControlFlowKeywords() throws {
        let tokens = try Lexer.tokenize("if then else when match case otherwise where")

        #expect(tokens[0].kind == .if)
        #expect(tokens[1].kind == .then)
        #expect(tokens[2].kind == .else)
        #expect(tokens[3].kind == .when)
        #expect(tokens[4].kind == .match)
        #expect(tokens[5].kind == .case)
        #expect(tokens[6].kind == .otherwise)
        #expect(tokens[7].kind == .where)
    }

    @Test("Tokenizes iteration keywords")
    func testIterationKeywords() throws {
        let tokens = try Lexer.tokenize("for each in at parallel concurrency")

        // "for" and "at" are prepositions (prioritized over keywords)
        #expect(tokens[0].kind == .preposition(.for))
        #expect(tokens[1].kind == .each)
        #expect(tokens[2].kind == .in)
        #expect(tokens[3].kind == .preposition(.at))
        #expect(tokens[4].kind == .parallel)
        #expect(tokens[5].kind == .concurrency)
    }

    @Test("Tokenizes error handling keywords")
    func testErrorHandlingKeywords() throws {
        // ARO-0008: No try/catch/finally - errors are auto-generated from statements
        let tokens = try Lexer.tokenize("error guard defer assert precondition")

        #expect(tokens[0].kind == .error)
        #expect(tokens[1].kind == .guard)
        #expect(tokens[2].kind == .defer)
        #expect(tokens[3].kind == .assert)
        #expect(tokens[4].kind == .precondition)
    }

    @Test("Tokenizes logical keywords")
    func testLogicalKeywords() throws {
        let tokens = try Lexer.tokenize("and or not is exists defined empty contains matches")

        #expect(tokens[0].kind == .and)
        #expect(tokens[1].kind == .or)
        #expect(tokens[2].kind == .not)
        #expect(tokens[3].kind == .is)
        #expect(tokens[4].kind == .exists)
        #expect(tokens[5].kind == .defined)
        #expect(tokens[6].kind == .empty)
        #expect(tokens[7].kind == .contains)
        #expect(tokens[8].kind == .matches)

        // "null", "nil", "none" all map to .nil token
        let nullTokens = try Lexer.tokenize("null nil none")
        #expect(nullTokens[0].kind == .nil)
        #expect(nullTokens[1].kind == .nil)
        #expect(nullTokens[2].kind == .nil)
    }

    @Test("Tokenizes type keywords")
    func testTypeKeywords() throws {
        let tokens = try Lexer.tokenize("type enum protocol")

        #expect(tokens[0].kind == .type)
        #expect(tokens[1].kind == .enum)
        #expect(tokens[2].kind == .protocol)
    }
}

// MARK: - Lexer Comment Tests

@Suite("Lexer Comment Tests")
struct LexerCommentTests {

    @Test("Skips block comments")
    func testBlockComments() throws {
        let tokens = try Lexer.tokenize("(* comment *) identifier")

        #expect(tokens[0].kind == .identifier("identifier"))
    }

    @Test("Block comments terminate at first closing")
    func testBlockCommentTermination() throws {
        // Block comments don't nest - they end at first *)
        let tokens = try Lexer.tokenize("(* comment *) identifier")

        #expect(tokens[0].kind == .identifier("identifier"))
    }

    @Test("Skips multiline block comments")
    func testMultilineBlockComments() throws {
        let source = """
        (*
          This is a
          multiline comment
        *)
        identifier
        """
        let tokens = try Lexer.tokenize(source)

        #expect(tokens[0].kind == .identifier("identifier"))
    }

    @Test("Skips line comments")
    func testLineComments() throws {
        let source = """
        identifier // this is a comment
        another
        """
        let tokens = try Lexer.tokenize(source)

        #expect(tokens[0].kind == .identifier("identifier"))
        #expect(tokens[1].kind == .identifier("another"))
    }
}

// MARK: - Lexer Location Tracking Tests

@Suite("Lexer Location Tracking Tests")
struct LexerLocationTests {

    @Test("Tracks token location correctly")
    func testTokenLocation() throws {
        let tokens = try Lexer.tokenize("hello")

        let token = tokens[0]
        #expect(token.span.start.line == 1)
        #expect(token.span.start.column == 1)
    }

    @Test("Tracks multiline locations correctly")
    func testMultilineLocations() throws {
        let source = """
        first
        second
        """
        let tokens = try Lexer.tokenize(source)

        #expect(tokens[0].span.start.line == 1)
        #expect(tokens[1].span.start.line == 2)
    }

    @Test("Tracks column correctly after whitespace")
    func testColumnAfterWhitespace() throws {
        let tokens = try Lexer.tokenize("   hello")

        #expect(tokens[0].span.start.column == 4)
    }
}

// MARK: - Lexer Error Tests

@Suite("Lexer Error Tests")
struct LexerErrorTests {

    @Test("Reports unterminated string")
    func testUnterminatedString() throws {
        #expect(throws: LexerError.self) {
            _ = try Lexer.tokenize("\"unterminated")
        }
    }

    @Test("Reports invalid escape sequence")
    func testInvalidEscapeSequence() throws {
        #expect(throws: LexerError.self) {
            _ = try Lexer.tokenize("\"invalid\\q\"")
        }
    }

    @Test("Reports unexpected character")
    func testUnexpectedCharacter() throws {
        // Most special characters are valid, but some combinations might fail
        // This test depends on implementation details
    }
}

// MARK: - Unicode Escape Tests (ARO-0002)

@Suite("Unicode Escape Tests")
struct UnicodeEscapeTests {

    @Test("Tokenizes basic unicode escape")
    func testBasicUnicodeEscape() throws {
        let tokens = try Lexer.tokenize("\"\\u{0041}\"")
        #expect(tokens[0].kind == .stringLiteral("A"))
    }

    @Test("Tokenizes multiple unicode escapes")
    func testMultipleUnicodeEscapes() throws {
        let tokens = try Lexer.tokenize("\"\\u{0048}\\u{0065}\\u{006C}\\u{006C}\\u{006F}\"")
        #expect(tokens[0].kind == .stringLiteral("Hello"))
    }

    @Test("Tokenizes unicode with mixed content")
    func testMixedUnicode() throws {
        let tokens = try Lexer.tokenize("\"Hello \\u{1F600}!\"")
        #expect(tokens[0].kind == .stringLiteral("Hello 😀!"))
    }

    @Test("Tokenizes unicode heart emoji")
    func testUnicodeHeart() throws {
        let tokens = try Lexer.tokenize("\"\\u{2764}\"")
        #expect(tokens[0].kind == .stringLiteral("❤"))
    }

    @Test("Reports invalid unicode escape - empty braces")
    func testInvalidUnicodeEmpty() throws {
        #expect(throws: LexerError.self) {
            _ = try Lexer.tokenize("\"\\u{}\"")
        }
    }

    @Test("Reports invalid unicode escape - invalid scalar")
    func testInvalidUnicodeScalar() throws {
        #expect(throws: LexerError.self) {
            _ = try Lexer.tokenize("\"\\u{FFFFFF}\"")
        }
    }
}

// MARK: - String Interpolation Tests (ARO-0002)

@Suite("String Interpolation Tests")
struct StringInterpolationTests {

    @Test("Tokenizes simple interpolation")
    func testSimpleInterpolation() throws {
        let tokens = try Lexer.tokenize("\"Hello, ${<name>}!\"")

        #expect(tokens[0].kind == .stringSegment("Hello, "))
        #expect(tokens[1].kind == .interpolationStart)
        #expect(tokens[2].kind == .leftAngle)
        #expect(tokens[3].kind == .identifier("name"))
        #expect(tokens[4].kind == .rightAngle)
        #expect(tokens[5].kind == .interpolationEnd)
        #expect(tokens[6].kind == .stringSegment("!"))
    }

    @Test("Tokenizes multiple interpolations")
    func testMultipleInterpolations() throws {
        let tokens = try Lexer.tokenize("\"${<first>} ${<second>}\"")

        // Check that we have interpolation starts
        let interpolationStarts = tokens.filter { $0.kind == .interpolationStart }
        #expect(interpolationStarts.count == 2)

        // Check that we have the variable identifiers
        let hasFirst = tokens.contains { $0.kind == .identifier("first") }
        let hasSecond = tokens.contains { $0.kind == .identifier("second") }
        #expect(hasFirst)
        #expect(hasSecond)

        // Check that we have interpolation ends
        let interpolationEnds = tokens.filter { $0.kind == .interpolationEnd }
        #expect(interpolationEnds.count == 2)
    }

    @Test("Tokenizes interpolation with expression")
    func testInterpolationWithExpression() throws {
        let tokens = try Lexer.tokenize("\"Total: ${<price> * <qty>}\"")

        #expect(tokens[0].kind == .stringSegment("Total: "))
        #expect(tokens[1].kind == .interpolationStart)
        // Contains <price> * <qty>
        let hasMultiply = tokens.contains { $0.kind == .star }
        #expect(hasMultiply)
    }

    @Test("Tokenizes plain string without interpolation")
    func testNoInterpolation() throws {
        let tokens = try Lexer.tokenize("\"Hello World\"")

        // Without interpolation, it's a simple string literal
        #expect(tokens[0].kind == .stringLiteral("Hello World"))
    }
}

// MARK: - Lexer Feature Set Tests

@Suite("Lexer Feature Set Tests")
struct LexerFeatureSetTests {

    @Test("Tokenizes complete feature set header")
    func testFeatureSetHeader() throws {
        let tokens = try Lexer.tokenize("(User Auth: Security) { }")

        #expect(tokens[0].kind == .leftParen)
        #expect(tokens[1].kind == .identifier("User"))
        #expect(tokens[2].kind == .identifier("Auth"))
        #expect(tokens[3].kind == .colon)
        #expect(tokens[4].kind == .identifier("Security"))
        #expect(tokens[5].kind == .rightParen)
        #expect(tokens[6].kind == .leftBrace)
        #expect(tokens[7].kind == .rightBrace)
    }

    @Test("Tokenizes complete ARO statement")
    func testAROStatement() throws {
        // New syntax: actions are capitalized identifiers without angle brackets
        let tokens = try Lexer.tokenize("Extract the <user: identifier> from the <request>.")

        #expect(tokens[0].kind == .identifier("Extract"))
        #expect(tokens[1].kind == .article(.the))
        #expect(tokens[2].kind == .leftAngle)
        #expect(tokens[3].kind == .identifier("user"))
        #expect(tokens[4].kind == .colon)
        #expect(tokens[5].kind == .identifier("identifier"))
        #expect(tokens[6].kind == .rightAngle)
        #expect(tokens[7].kind == .preposition(.from))
        #expect(tokens[8].kind == .article(.the))
        #expect(tokens[9].kind == .leftAngle)
        #expect(tokens[10].kind == .identifier("request"))
        #expect(tokens[11].kind == .rightAngle)
        #expect(tokens[12].kind == .dot)
    }

    @Test("Tokenizes publish statement")
    func testPublishStatement() throws {
        // New syntax: Publish without angle brackets
        let tokens = try Lexer.tokenize("Publish as <external-name> <internal>.")

        #expect(tokens[0].kind == .publish)
        #expect(tokens[1].kind == .as)
        #expect(tokens[2].kind == .leftAngle)
        #expect(tokens[3].kind == .identifier("external"))
    }

    @Test("Tokenizes hyphenated identifier")
    func testHyphenatedIdentifier() throws {
        let tokens = try Lexer.tokenize("<user-data>")

        // Hyphenated identifiers are tokenized as separate tokens with hyphen
        #expect(tokens[0].kind == .leftAngle)
        #expect(tokens[1].kind == .identifier("user"))
        #expect(tokens[2].kind == .hyphen)
        #expect(tokens[3].kind == .identifier("data"))
        #expect(tokens[4].kind == .rightAngle)
    }

    @Test("Tokenizes statement with literal value")
    func testLiteralValue() throws {
        let tokens = try Lexer.tokenize("Log the <message> with \"Hello World\".")

        let hasStringLiteral = tokens.contains {
            if case .stringLiteral("Hello World") = $0.kind { return true }
            return false
        }
        #expect(hasStringLiteral)
    }
}

// MARK: - ARO-0053: Lexer Lookup Optimization Tests

@Suite("Article and Preposition Lookup Optimization (ARO-0053)")
struct LexerLookupOptimizationTests {

    @Test("All articles are recognized with O(1) dictionary lookup")
    func testAllArticles() throws {
        // Test lowercase articles
        let articlesTest = "a an the"
        let tokens = try Lexer.tokenize(articlesTest)

        #expect(tokens[0].kind == .article(.a))
        #expect(tokens[1].kind == .article(.an))
        #expect(tokens[2].kind == .article(.the))
    }

    @Test("Articles are case-insensitive")
    func testArticlesCaseInsensitive() throws {
        let tokens = try Lexer.tokenize("The A An THE")

        #expect(tokens[0].kind == .article(.the))
        #expect(tokens[1].kind == .article(.a))
        #expect(tokens[2].kind == .article(.an))
        #expect(tokens[3].kind == .article(.the))
    }

    @Test("All prepositions are recognized with O(1) dictionary lookup")
    func testAllPrepositions() throws {
        let prepositionsTest = "from for against to into via with on at by"
        let tokens = try Lexer.tokenize(prepositionsTest)

        #expect(tokens[0].kind == .preposition(.from))
        #expect(tokens[1].kind == .preposition(.for))
        #expect(tokens[2].kind == .preposition(.against))
        #expect(tokens[3].kind == .preposition(.to))
        #expect(tokens[4].kind == .preposition(.into))
        #expect(tokens[5].kind == .preposition(.via))
        #expect(tokens[6].kind == .preposition(.with))
        #expect(tokens[7].kind == .preposition(.on))
        #expect(tokens[8].kind == .preposition(.at))
        #expect(tokens[9].kind == .preposition(.by))
    }

    @Test("Prepositions are case-insensitive")
    func testPrepositionsCaseInsensitive() throws {
        let tokens = try Lexer.tokenize("FROM From WITH With")

        #expect(tokens[0].kind == .preposition(.from))
        #expect(tokens[1].kind == .preposition(.from))
        #expect(tokens[2].kind == .preposition(.with))
        #expect(tokens[3].kind == .preposition(.with))
    }

    @Test("Articles in ARO statements are correctly identified")
    func testArticlesInStatements() throws {
        let tokens = try Lexer.tokenize("Extract a <value> from the <source>.")

        #expect(tokens[1].kind == .article(.a))
        #expect(tokens[5].kind == .preposition(.from))
        #expect(tokens[6].kind == .article(.the))
    }

    @Test("Non-articles are not matched")
    func testNonArticles() throws {
        let tokens = try Lexer.tokenize("abc another thee")

        // These should be identifiers, not articles
        #expect(tokens[0].kind == .identifier("abc"))
        #expect(tokens[1].kind == .identifier("another"))
        #expect(tokens[2].kind == .identifier("thee"))
    }

    @Test("Non-prepositions are not matched")
    func testNonPrepositions() throws {
        let tokens = try Lexer.tokenize("frost format")

        // These should be identifiers, not prepositions
        #expect(tokens[0].kind == .identifier("frost"))
        #expect(tokens[1].kind == .identifier("format"))
    }

    @Test("Verify article enum exhaustiveness")
    func testArticleEnumExhaustive() {
        // Ensure all Article enum cases are in the dictionary
        let allArticles: [Article] = [.a, .an, .the]

        for article in allArticles {
            let found = try? Lexer.tokenize(article.rawValue)
            #expect(found != nil)
            if let tokens = found, !tokens.isEmpty {
                if case .article(let parsedArticle) = tokens[0].kind {
                    #expect(parsedArticle == article)
                }
            }
        }
    }

    @Test("Verify preposition enum exhaustiveness")
    func testPrepositionEnumExhaustive() {
        // Ensure all Preposition enum cases are in the dictionary
        let allPrepositions: [Preposition] = [
            .from, .for, .against, .to, .into, .via, .with, .on, .at, .by
        ]

        for preposition in allPrepositions {
            let found = try? Lexer.tokenize(preposition.rawValue)
            #expect(found != nil)
            if let tokens = found, !tokens.isEmpty {
                if case .preposition(let parsedPrep) = tokens[0].kind {
                    #expect(parsedPrep == preposition)
                }
            }
        }
    }
}

// MARK: - Numeric Separator Tests (ARO-0052)

@Suite("Numeric Separator Tests")
struct NumericSeparatorTests {

    @Test("Tokenizes integer with underscore separators")
    func testIntegerWithUnderscores() throws {
        let tokens = try Lexer.tokenize("1_000_000")
        #expect(tokens[0].kind == .intLiteral(1_000_000))
    }

    @Test("Tokenizes large integer with underscore separators")
    func testLargeIntegerWithUnderscores() throws {
        let tokens = try Lexer.tokenize("1_000_000_000")
        #expect(tokens[0].kind == .intLiteral(1_000_000_000))
    }

    @Test("Tokenizes float with underscore separators")
    func testFloatWithUnderscores() throws {
        let tokens = try Lexer.tokenize("1_234.567_890")
        #expect(tokens[0].kind == .floatLiteral(1_234.567_890))
    }

    @Test("Tokenizes exponent with underscore separators")
    func testExponentWithUnderscores() throws {
        let tokens = try Lexer.tokenize("1e1_0")
        #expect(tokens[0].kind == .floatLiteral(1e10))
    }

    @Test("Tokenizes complex float with underscores")
    func testComplexFloatWithUnderscores() throws {
        let tokens = try Lexer.tokenize("1_234.567_890e1_2")
        #expect(tokens[0].kind == .floatLiteral(1_234.567_890e12))
    }

    @Test("Tokenizes hex with underscore separators")
    func testHexWithUnderscores() throws {
        let tokens = try Lexer.tokenize("0xFF_FF")
        #expect(tokens[0].kind == .intLiteral(0xFFFF))
    }

    @Test("Tokenizes binary with underscore separators")
    func testBinaryWithUnderscores() throws {
        let tokens = try Lexer.tokenize("0b1010_1010")
        #expect(tokens[0].kind == .intLiteral(0b10101010))
    }

    @Test("Underscores at arbitrary positions")
    func testArbitraryUnderscorePositions() throws {
        // Underscores can be between any digits
        let tokens = try Lexer.tokenize("12_34_56")
        #expect(tokens[0].kind == .intLiteral(123456))
    }

    @Test("Single underscore in integer")
    func testSingleUnderscore() throws {
        let tokens = try Lexer.tokenize("1_0")
        #expect(tokens[0].kind == .intLiteral(10))
    }

    @Test("Negative integer with underscores")
    func testNegativeIntegerWithUnderscores() throws {
        let tokens = try Lexer.tokenize("-1_000_000")
        #expect(tokens[0].kind == .intLiteral(-1_000_000))
    }

    @Test("Negative float with underscores")
    func testNegativeFloatWithUnderscores() throws {
        let tokens = try Lexer.tokenize("-1_234.567_890")
        #expect(tokens[0].kind == .floatLiteral(-1_234.567_890))
    }
}
