// ============================================================
// IterationTests.swift
// ARO Parser - ARO-0005 Iteration Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - For-Each Loop Parsing Tests

@Suite("For-Each Loop Parsing Tests")
struct ForEachLoopParsingTests {

    @Test("Parses basic for-each loop")
    func testParseBasicForEachLoop() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            for each <item> in <items> {
                <Log> <item> to the <console>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.featureSets.count == 1)
        let statements = program.featureSets[0].statements
        #expect(statements.count == 3)

        let forEach = statements[1] as? ForEachLoop
        #expect(forEach != nil)
        #expect(forEach?.itemVariable == "item")
        #expect(forEach?.indexVariable == nil)
        #expect(forEach?.collection.base == "items")
        #expect(forEach?.filter == nil)
        #expect(forEach?.isParallel == false)
        #expect(forEach?.concurrency == nil)
        #expect(forEach?.body.count == 1)
    }

    @Test("Parses for-each loop with index")
    func testParseForEachLoopWithIndex() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            for each <item> at <index> in <items> {
                <Log> <index> to the <console>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let forEach = program.featureSets[0].statements[1] as? ForEachLoop
        #expect(forEach != nil)
        #expect(forEach?.itemVariable == "item")
        #expect(forEach?.indexVariable == "index")
        #expect(forEach?.collection.base == "items")
    }

    @Test("Parses for-each loop with where filter")
    func testParseForEachLoopWithFilter() throws {
        let source = """
        (Test: Demo) {
            <Create> the <users> with [].
            for each <user> in <users> where <user: active> is true {
                <Log> <user> to the <console>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let forEach = program.featureSets[0].statements[1] as? ForEachLoop
        #expect(forEach != nil)
        #expect(forEach?.filter != nil)

        // Filter should be a binary expression
        let filter = forEach?.filter as? BinaryExpression
        #expect(filter != nil)
        #expect(filter?.op == .equal)
    }

    @Test("Parses parallel for-each loop")
    func testParseParallelForEachLoop() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            parallel for each <item> in <items> {
                <Process> the <result> for the <item>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let forEach = program.featureSets[0].statements[1] as? ForEachLoop
        #expect(forEach != nil)
        #expect(forEach?.isParallel == true)
        #expect(forEach?.concurrency == nil)
    }

    @Test("Parses parallel for-each loop with concurrency limit")
    func testParseParallelForEachLoopWithConcurrency() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            parallel for each <item> in <items> with <concurrency: 4> {
                <Fetch> the <data> from the <api>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let forEach = program.featureSets[0].statements[1] as? ForEachLoop
        #expect(forEach != nil)
        #expect(forEach?.isParallel == true)
        #expect(forEach?.concurrency == 4)
    }

    @Test("Parses nested for-each loops")
    func testParseNestedForEachLoops() throws {
        let source = """
        (Test: Demo) {
            <Create> the <outer> with [[1, 2], [3, 4]].
            for each <row> in <outer> {
                for each <cell> in <row> {
                    <Log> <cell> to the <console>.
                }
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        let outerForEach = program.featureSets[0].statements[1] as? ForEachLoop
        #expect(outerForEach != nil)
        #expect(outerForEach?.body.count == 1)

        let innerForEach = outerForEach?.body[0] as? ForEachLoop
        #expect(innerForEach != nil)
        #expect(innerForEach?.itemVariable == "cell")
        #expect(innerForEach?.collection.base == "row")
    }
}

// MARK: - For-Each Loop Semantic Tests

@Suite("For-Each Loop Semantic Tests")
struct ForEachLoopSemanticTests {

    @Test("Collection variable must be defined")
    func testCollectionMustBeDefined() throws {
        let source = """
        (Test: Demo) {
            for each <item> in <undefined-collection> {
                <Log> <item> to the <console>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        // Should have a warning about undefined collection
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        let undefinedWarning = warnings.first { $0.message.contains("undefined-collection") }
        #expect(undefinedWarning != nil)
    }

    @Test("Loop variable is available in body")
    func testLoopVariableAvailable() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            for each <item> in <items> {
                <Compute> the <doubled> from <item> * 2.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        // Should compile without errors about 'item' being undefined
        #expect(result.isSuccess)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Parallel loop tracks concurrency side effect")
    func testParallelLoopSideEffect() throws {
        let source = """
        (Test: Demo) {
            <Create> the <items> with [1, 2, 3].
            parallel for each <item> in <items> with <concurrency: 4> {
                <Process> the <result> for the <item>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        #expect(result.isSuccess)
        let dataFlows = result.analyzedProgram.featureSets[0].dataFlows
        // The for-each loop should be the second statement (index 1)
        let forEachFlow = dataFlows[1]
        let hasParallelEffect = forEachFlow.sideEffects.contains { $0.contains("parallel") }
        #expect(hasParallelEffect)
    }
}
