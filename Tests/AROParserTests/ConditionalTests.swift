// ============================================================
// ConditionalTests.swift
// ARO Parser - ARO-0004 Conditional Branching Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Match Statement Parsing Tests

@Suite("Match Statement Parsing Tests")
struct MatchStatementParsingTests {

    @Test("Parses simple match with string cases")
    func testParseMatchWithStringCases() throws {
        let source = """
        (Test: Demo) {
            Create the <method> with "GET".
            match <method> {
                case "GET" {
                    Return an <OK: status> for the <request>.
                }
                case "POST" {
                    Return a <Created: status> for the <request>.
                }
                otherwise {
                    Return a <BadRequest: status> for the <request>.
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
        #expect(matchStmt?.subject.base == "method")
        #expect(matchStmt?.cases.count == 2)
        #expect(matchStmt?.otherwise != nil)
        #expect(matchStmt?.otherwise?.count == 1)

        // Check first case
        if case .literal(.string("GET")) = matchStmt?.cases[0].pattern {
            // OK
        } else {
            Issue.record("Expected string literal 'GET' pattern")
        }
    }

    @Test("Parses match with integer cases")
    func testParseMatchWithIntegerCases() throws {
        let source = """
        (Test: Demo) {
            Create the <code> with 200.
            match <code> {
                case 200 {
                    Return an <OK: status> for the <request>.
                }
                case 404 {
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
        #expect(matchStmt != nil)
        #expect(matchStmt?.cases.count == 2)

        // Check first case is integer
        if case .literal(.integer(200)) = matchStmt?.cases[0].pattern {
            // OK
        } else {
            Issue.record("Expected integer literal 200 pattern")
        }
    }

    @Test("Parses match with variable pattern")
    func testParseMatchWithVariablePattern() throws {
        let source = """
        (Test: Demo) {
            Create the <expected> with "admin".
            Create the <role> with "admin".
            match <role> {
                case <expected> {
                    Return an <OK: status> for the <request>.
                }
                otherwise {
                    Return a <BadRequest: status> for the <request>.
                }
            }
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let matchStmt = statements[2] as? MatchStatement
        #expect(matchStmt != nil)

        // Check first case is variable pattern
        if case .variable(let noun) = matchStmt?.cases[0].pattern {
            #expect(noun.base == "expected")
        } else {
            Issue.record("Expected variable pattern")
        }
    }

    @Test("Parses match with guard condition")
    func testParseMatchWithGuardCondition() throws {
        let source = """
        (Test: Demo) {
            Create the <user> with "premium".
            Create the <credits> with 100.
            match <user> {
                case "premium" where <credits> > 0 {
                    Return an <OK: status> for the <request>.
                }
                otherwise {
                    Return a <BadRequest: status> for the <request>.
                }
            }
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let matchStmt = statements[2] as? MatchStatement
        #expect(matchStmt != nil)
        #expect(matchStmt?.cases[0].guardCondition != nil)

        // Check guard is a binary expression
        let guard_ = matchStmt?.cases[0].guardCondition as? BinaryExpression
        #expect(guard_ != nil)
        #expect(guard_?.op == .greaterThan)
    }
}

// MARK: - When Clause Parsing Tests

@Suite("When Clause Parsing Tests")
struct WhenClauseParsingTests {

    @Test("Parses statement with when clause")
    func testParseStatementWithWhenClause() throws {
        let source = """
        (Test: Demo) {
            Create the <role> with "admin".
            Log "Admin!" to the <console> when <role> == "admin".
            Return an <OK: status> for the <request>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        #expect(statements.count == 3)

        let logStmt = statements[1] as? AROStatement
        #expect(logStmt != nil)
        #expect(logStmt?.whenCondition != nil)

        // Check when condition is a binary expression
        let whenCond = logStmt?.whenCondition as? BinaryExpression
        #expect(whenCond != nil)
        #expect(whenCond?.op == .equal)
    }

    @Test("Parses statement with complex when condition")
    func testParseStatementWithComplexWhenCondition() throws {
        let source = """
        (Test: Demo) {
            Create the <age> with 25.
            Create the <verified> with true.
            Return an <OK: status> for the <request> when <age> >= 18 and <verified> == true.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let returnStmt = statements[2] as? AROStatement
        #expect(returnStmt != nil)
        #expect(returnStmt?.whenCondition != nil)

        // Check when condition is a binary 'and' expression
        let whenCond = returnStmt?.whenCondition as? BinaryExpression
        #expect(whenCond != nil)
        #expect(whenCond?.op == .and)
    }

    @Test("Parses statement without when clause")
    func testParseStatementWithoutWhenClause() throws {
        let source = """
        (Test: Demo) {
            Return an <OK: status> for the <request>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let returnStmt = statements[0] as? AROStatement
        #expect(returnStmt != nil)
        #expect(returnStmt?.whenCondition == nil)
    }
}

// MARK: - Match Statement Semantic Tests

@Suite("Match Statement Semantic Tests")
struct MatchStatementSemanticTests {

    @Test("Match subject variable must be defined")
    func testMatchSubjectMustBeDefined() throws {
        let source = """
        (Test: Demo) {
            match <undefined-var> {
                case "value" {
                    Return an <OK: status> for the <request>.
                }
            }
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        // Should have a warning about undefined variable
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        let undefinedWarning = warnings.first { $0.message.contains("undefined-var") }
        #expect(undefinedWarning != nil)
    }

    @Test("Variables from when clause are tracked")
    func testWhenClauseVariablesTracked() throws {
        let source = """
        (Test: Demo) {
            Create the <role> with "admin".
            Log "Admin!" to the <console> when <role> == "admin".
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(result.isSuccess)
        let dataFlows = result.analyzedProgram.featureSets[0].dataFlows
        // The when condition should use the 'role' variable
        let logFlow = dataFlows[1]
        #expect(logFlow.inputs.contains("role"))
    }
}
