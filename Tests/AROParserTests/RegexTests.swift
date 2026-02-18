// ============================================================
// RegexTests.swift
// ARO Parser - ARO-0037 Regular Expression Literal Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Regex Lexer Tests

@Suite("Regex Lexer Tests")
struct RegexLexerTests {

    @Test("Lexer tokenizes simple regex literal")
    func testSimpleRegex() throws {
        let source = "/^hello/"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        #expect(tokens.count == 2) // regex + EOF
        if case .regexLiteral(let pattern, let flags) = tokens[0].kind {
            #expect(pattern == "^hello")
            #expect(flags == "")
        } else {
            Issue.record("Expected regex literal token")
        }
    }

    @Test("Lexer tokenizes regex with flags")
    func testRegexWithFlags() throws {
        let source = "/^[a-z]+$/i"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        #expect(tokens.count == 2)
        if case .regexLiteral(let pattern, let flags) = tokens[0].kind {
            #expect(pattern == "^[a-z]+$")
            #expect(flags == "i")
        } else {
            Issue.record("Expected regex literal token")
        }
    }

    @Test("Lexer tokenizes regex with multiple flags")
    func testRegexWithMultipleFlags() throws {
        let source = "/pattern/ism"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        #expect(tokens.count == 2)
        if case .regexLiteral(let pattern, let flags) = tokens[0].kind {
            #expect(pattern == "pattern")
            #expect(flags == "ism")
        } else {
            Issue.record("Expected regex literal token")
        }
    }

    @Test("Lexer handles escaped slashes in regex")
    func testRegexEscapedSlash() throws {
        let source = "/path\\/to\\/file/"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        #expect(tokens.count == 2)
        if case .regexLiteral(let pattern, let flags) = tokens[0].kind {
            #expect(pattern == "path\\/to\\/file")
            #expect(flags == "")
        } else {
            Issue.record("Expected regex literal token")
        }
    }

    @Test("Lexer handles complex email regex")
    func testComplexEmailRegex() throws {
        let source = "/^[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$/i"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        #expect(tokens.count == 2)
        if case .regexLiteral(let pattern, let flags) = tokens[0].kind {
            #expect(pattern == "^[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}$")
            #expect(flags == "i")
        } else {
            Issue.record("Expected regex literal token")
        }
    }

    @Test("Slash with space is division operator")
    func testSlashWithSpaceIsDivision() throws {
        let source = "a / b"
        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()

        // Should be: identifier, slash, identifier, EOF
        #expect(tokens.count == 4)
        #expect(tokens[1].kind == .slash)
    }
}

// MARK: - Regex Parser Tests

@Suite("Regex Parser Tests")
struct RegexParserTests {

    @Test("Parser creates regex pattern in match statement")
    func testRegexPatternInMatch() throws {
        let source = """
        (Test: Demo) {
            Create the <text> with "hello".
            match <text> {
                case /^hello/ {
                    Return an <OK: status> for the <request>.
                }
            }
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.featureSets.count == 1)
        let statements = program.featureSets[0].statements
        #expect(statements.count == 2)

        let matchStmt = statements[1] as? MatchStatement
        #expect(matchStmt != nil)
        #expect(matchStmt?.cases.count == 1)

        if case .regex(let pattern, let flags) = matchStmt?.cases[0].pattern {
            #expect(pattern == "^hello")
            #expect(flags == "")
        } else {
            Issue.record("Expected regex pattern")
        }
    }

    @Test("Parser creates regex pattern with flags")
    func testRegexPatternWithFlags() throws {
        let source = """
        (Test: Demo) {
            Create the <text> with "HELLO".
            match <text> {
                case /^hello/i {
                    Return an <OK: status> for the <request>.
                }
            }
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let matchStmt = statements[1] as? MatchStatement

        if case .regex(let pattern, let flags) = matchStmt?.cases[0].pattern {
            #expect(pattern == "^hello")
            #expect(flags == "i")
        } else {
            Issue.record("Expected regex pattern with flags")
        }
    }

    @Test("Parser handles mixed string and regex cases")
    func testMixedCases() throws {
        let source = """
        (Test: Demo) {
            Create the <msg> with "test".
            match <msg> {
                case "exact" {
                    Return an <OK: status> for the <request>.
                }
                case /^prefix/ {
                    Return an <OK: status> for the <request>.
                }
                otherwise {
                    Return a <NotFound: status> for the <request>.
                }
            }
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let matchStmt = statements[1] as? MatchStatement
        #expect(matchStmt?.cases.count == 2)
        #expect(matchStmt?.otherwise != nil)

        // First case is string literal
        if case .literal(.string("exact")) = matchStmt?.cases[0].pattern {
            // OK
        } else {
            Issue.record("Expected string literal pattern")
        }

        // Second case is regex
        if case .regex(let pattern, _) = matchStmt?.cases[1].pattern {
            #expect(pattern == "^prefix")
        } else {
            Issue.record("Expected regex pattern")
        }
    }

    @Test("Parser handles regex in where clause expression")
    func testRegexInWhereClause() throws {
        let source = """
        (Test: Demo) {
            Retrieve the <users> from the <user-repository>
                where <name> matches /^Admin/i.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.featureSets.count == 1)
        let statements = program.featureSets[0].statements
        #expect(statements.count == 1)

        let aroStmt = statements[0] as? AROStatement
        #expect(aroStmt != nil)
        #expect(aroStmt?.whereClause != nil)
    }
}

// MARK: - Regex AST Tests

@Suite("Regex AST Tests")
struct RegexASTTests {

    @Test("Regex pattern enum case stores pattern and flags")
    func testRegexPatternEnum() {
        let pattern = Pattern.regex(pattern: "^test$", flags: "ism")

        if case .regex(let p, let f) = pattern {
            #expect(p == "^test$")
            #expect(f == "ism")
        } else {
            Issue.record("Pattern should be regex case")
        }
    }

    @Test("Regex literal value stores pattern and flags")
    func testRegexLiteralValue() {
        let literal = LiteralValue.regex(pattern: "[a-z]+", flags: "i")

        if case .regex(let p, let f) = literal {
            #expect(p == "[a-z]+")
            #expect(f == "i")
        } else {
            Issue.record("Literal should be regex case")
        }
    }
}
