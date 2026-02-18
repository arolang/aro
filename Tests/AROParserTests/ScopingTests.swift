// ============================================================
// ScopingTests.swift
// ARO Parser - ARO-0003 Variable Scoping Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Require Statement Parsing Tests

@Suite("Require Statement Parsing Tests")
struct RequireStatementParsingTests {

    @Test("Parses require from framework")
    func testRequireFromFramework() throws {
        let source = """
        (Test: Demo) {
            Require the <request> from the <framework>.
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.featureSets.count == 1)
        let statements = program.featureSets[0].statements
        #expect(statements.count == 2)

        let requireStmt = statements[0] as? RequireStatement
        #expect(requireStmt != nil)
        #expect(requireStmt?.variableName == "request")
        #expect(requireStmt?.source == .framework)
    }

    @Test("Parses require from environment")
    func testRequireFromEnvironment() throws {
        let source = """
        (Test: Demo) {
            Require the <api-key> from the <environment>.
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let requireStmt = statements[0] as? RequireStatement
        #expect(requireStmt != nil)
        #expect(requireStmt?.variableName == "api-key")
        #expect(requireStmt?.source == .environment)
    }

    @Test("Parses require from feature set")
    func testRequireFromFeatureSet() throws {
        let source = """
        (Test: Demo) {
            Require the <user> from the <auth-service>.
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let statements = program.featureSets[0].statements
        let requireStmt = statements[0] as? RequireStatement
        #expect(requireStmt != nil)
        #expect(requireStmt?.variableName == "user")
        #expect(requireStmt?.source == .featureSet("auth-service"))
    }

    @Test("Require statement description")
    func testRequireStatementDescription() {
        let span = SourceSpan(at: SourceLocation())
        let stmt = RequireStatement(
            variableName: "database",
            source: .framework,
            span: span
        )

        #expect(stmt.description == "Require the <database> from the <framework>.")
    }
}

// MARK: - Require Source Tests

@Suite("Require Source Tests")
struct RequireSourceTests {

    @Test("RequireSource equality")
    func testRequireSourceEquality() {
        #expect(RequireSource.framework == RequireSource.framework)
        #expect(RequireSource.environment == RequireSource.environment)
        #expect(RequireSource.featureSet("A") == RequireSource.featureSet("A"))
        #expect(RequireSource.featureSet("A") != RequireSource.featureSet("B"))
        #expect(RequireSource.framework != RequireSource.environment)
    }

    @Test("RequireSource description")
    func testRequireSourceDescription() {
        #expect(RequireSource.framework.description == "framework")
        #expect(RequireSource.environment.description == "environment")
        #expect(RequireSource.featureSet("auth").description == "auth")
    }
}

// MARK: - Semantic Analyzer Scoping Tests

@Suite("Semantic Analyzer Scoping Tests")
struct SemanticAnalyzerScopingTests {

    @Test("Require statement adds to dependencies")
    func testRequireAddsDependency() throws {
        let source = """
        (Test: Demo) {
            Require the <database> from the <framework>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(result.isSuccess)
        let analyzed = result.analyzedProgram.featureSets[0]
        #expect(analyzed.dependencies.contains("database"))
    }

    @Test("Published variable updates visibility")
    func testPublishedVariableVisibility() throws {
        let source = """
        (Test: Demo) {
            Create the <user> with "John".
            Publish as <current-user> <user>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(result.isSuccess)
        let symbolTable = result.analyzedProgram.featureSets[0].symbolTable
        let userSymbol = symbolTable.lookup("user")
        #expect(userSymbol?.visibility == .published)

        let aliasSymbol = symbolTable.lookup("current-user")
        #expect(aliasSymbol?.visibility == .published)
        if case .alias(let of) = aliasSymbol?.source {
            #expect(of == "user")
        } else {
            Issue.record("Expected alias source")
        }
    }

    @Test("Require statement registers as external")
    func testRequireRegistersExternal() throws {
        let source = """
        (Test: Demo) {
            Require the <request> from the <framework>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(result.isSuccess)
        let symbolTable = result.analyzedProgram.featureSets[0].symbolTable
        let requestSymbol = symbolTable.lookup("request")
        #expect(requestSymbol?.visibility == .external)
    }
}

// MARK: - Unused Variable Detection Tests

@Suite("Unused Variable Detection Tests")
struct UnusedVariableDetectionTests {

    @Test("Warns about unused variable")
    func testWarnsUnusedVariable() throws {
        let source = """
        (Test: Demo) {
            Create the <used-var> with "hello".
            Create the <unused-var> with "world".
            Log <used-var> to the <console>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let warnings = result.diagnostics.filter { $0.severity == .warning }
        let unusedWarning = warnings.first { $0.message.contains("unused-var") && $0.message.contains("never used") }
        #expect(unusedWarning != nil)
    }

    @Test("Does not warn about published variable")
    func testNoWarningForPublishedVariable() throws {
        let source = """
        (Test: Demo) {
            Create the <user> with "John".
            Publish as <current-user> <user>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let warnings = result.diagnostics.filter { $0.severity == .warning }
        let userUnusedWarning = warnings.first { $0.message.contains("'user'") && $0.message.contains("never used") }
        #expect(userUnusedWarning == nil, "Published variables should not trigger unused warning")
    }

    @Test("Does not warn about external dependency")
    func testNoWarningForExternalDependency() throws {
        let source = """
        (Test: Demo) {
            Require the <database> from the <framework>.
            Return an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let warnings = result.diagnostics.filter { $0.severity == .warning }
        let databaseWarning = warnings.first { $0.message.contains("'database'") && $0.message.contains("never used") }
        #expect(databaseWarning == nil, "Required external variables should not trigger unused warning")
    }
}
