// ============================================================
// ParserTests.swift
// ARO Parser - Comprehensive Parser Unit Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - AST Node Tests

@Suite("AST Node Tests")
struct ASTNodeTests {

    @Test("Program creation and description")
    func testProgramCreation() {
        let span = SourceSpan(at: SourceLocation())
        let program = Program(featureSets: [], span: span)

        #expect(program.featureSets.isEmpty)
        #expect(program.description == "Program(0 feature sets)")
    }

    @Test("FeatureSet creation and description")
    func testFeatureSetCreation() {
        let span = SourceSpan(at: SourceLocation())
        let featureSet = FeatureSet(
            name: "User Auth",
            businessActivity: "Security",
            statements: [],
            span: span
        )

        #expect(featureSet.name == "User Auth")
        #expect(featureSet.businessActivity == "Security")
        #expect(featureSet.statements.isEmpty)
        #expect(featureSet.description == "FeatureSet(User Auth: Security, 0 statements)")
    }

    @Test("Action creation and semantic role classification")
    func testActionCreation() {
        let span = SourceSpan(at: SourceLocation())

        let extractAction = Action(verb: "Extract", span: span)
        #expect(extractAction.semanticRole == .request)

        let computeAction = Action(verb: "Compute", span: span)
        #expect(computeAction.semanticRole == .own)

        let returnAction = Action(verb: "Return", span: span)
        #expect(returnAction.semanticRole == .response)

        let publishAction = Action(verb: "Publish", span: span)
        #expect(publishAction.semanticRole == .export)
    }

    @Test("QualifiedNoun creation and fullName")
    func testQualifiedNounCreation() {
        let span = SourceSpan(at: SourceLocation())

        let simpleNoun = QualifiedNoun(base: "user", span: span)
        #expect(simpleNoun.fullName == "user")
        #expect(simpleNoun.description == "user")

        let qualifiedNoun = QualifiedNoun(base: "user", specifiers: ["id", "name"], span: span)
        #expect(qualifiedNoun.fullName == "user: id.name")
        #expect(qualifiedNoun.description == "user: id.name")
    }

    @Test("ObjectClause creation and external reference")
    func testObjectClauseCreation() {
        let span = SourceSpan(at: SourceLocation())
        let noun = QualifiedNoun(base: "request", span: span)

        let fromClause = ObjectClause(preposition: .from, noun: noun)
        #expect(fromClause.isExternalReference == true)

        let forClause = ObjectClause(preposition: .for, noun: noun)
        #expect(forClause.isExternalReference == false)
    }

    @Test("LiteralValue types and descriptions")
    func testLiteralValueTypes() {
        #expect(LiteralValue.string("hello").description == "\"hello\"")
        #expect(LiteralValue.integer(42).description == "42")
        #expect(LiteralValue.float(3.14).description == "3.14")
        #expect(LiteralValue.boolean(true).description == "true")
        #expect(LiteralValue.boolean(false).description == "false")
        #expect(LiteralValue.null.description == "null")
    }

    @Test("AROStatement creation and description")
    func testAROStatementCreation() {
        let span = SourceSpan(at: SourceLocation())
        let action = Action(verb: "Extract", span: span)
        let result = QualifiedNoun(base: "user", span: span)
        let object = ObjectClause(preposition: .from, noun: QualifiedNoun(base: "request", span: span))

        let statement = AROStatement(action: action, result: result, object: object, span: span)
        #expect(statement.action.verb == "Extract")
        #expect(statement.result.base == "user")
        #expect(statement.object.preposition == .from)
    }

    @Test("PublishStatement creation and description")
    func testPublishStatementCreation() {
        let span = SourceSpan(at: SourceLocation())
        let statement = PublishStatement(externalName: "user-data", internalVariable: "data", span: span)

        #expect(statement.externalName == "user-data")
        #expect(statement.internalVariable == "data")
        #expect(statement.description.contains("user-data"))
    }
}

// MARK: - Action Semantic Role Tests

@Suite("Action Semantic Role Tests")
struct ActionSemanticRoleTests {

    @Test("Request verbs are classified correctly")
    func testRequestVerbs() {
        let requestVerbs = ["extract", "parse", "retrieve", "fetch", "read", "receive", "get", "load"]
        for verb in requestVerbs {
            #expect(ActionSemanticRole.classify(verb: verb) == .request)
        }
    }

    @Test("Response verbs are classified correctly")
    func testResponseVerbs() {
        let responseVerbs = ["return", "throw", "send", "emit", "respond", "output", "write"]
        for verb in responseVerbs {
            #expect(ActionSemanticRole.classify(verb: verb) == .response)
        }
    }

    @Test("Export verbs are classified correctly")
    func testExportVerbs() {
        let exportVerbs = ["publish", "export", "expose", "share"]
        for verb in exportVerbs {
            #expect(ActionSemanticRole.classify(verb: verb) == .export)
        }
    }

    @Test("Own verbs are classified correctly")
    func testOwnVerbs() {
        let ownVerbs = ["compute", "validate", "compare", "transform", "create", "process"]
        for verb in ownVerbs {
            #expect(ActionSemanticRole.classify(verb: verb) == .own)
        }
    }

    @Test("Classification is case insensitive")
    func testCaseInsensitiveClassification() {
        #expect(ActionSemanticRole.classify(verb: "EXTRACT") == .request)
        #expect(ActionSemanticRole.classify(verb: "Extract") == .request)
        #expect(ActionSemanticRole.classify(verb: "eXtRaCt") == .request)
    }
}

// MARK: - Parser Basic Tests

@Suite("Parser Basic Tests")
struct ParserBasicTests {

    @Test("Parses empty source")
    func testEmptySource() throws {
        let program = try Parser.parse("")
        #expect(program.featureSets.isEmpty)
    }

    @Test("Parses simple feature set")
    func testSimpleFeatureSet() throws {
        let source = """
        (User Auth: Security) {
            <Extract> the <user> from the <request>.
        }
        """
        let program = try Parser.parse(source)

        #expect(program.featureSets.count == 1)
        #expect(program.featureSets[0].name == "User Auth")
        #expect(program.featureSets[0].businessActivity == "Security")
        #expect(program.featureSets[0].statements.count == 1)
    }

    @Test("Parses multiple feature sets")
    func testMultipleFeatureSets() throws {
        let source = """
        (Feature One: Activity One) {
            <Extract> the <data> from the <source>.
        }
        (Feature Two: Activity Two) {
            <Compute> the <result> for the <input>.
        }
        """
        let program = try Parser.parse(source)

        #expect(program.featureSets.count == 2)
        #expect(program.featureSets[0].name == "Feature One")
        #expect(program.featureSets[1].name == "Feature Two")
    }

    @Test("Parses feature set with hyphenated name")
    func testHyphenatedFeatureSetName() throws {
        let source = """
        (Application-Start: Entry Point) {
            <Log> <message> to the <console>.
        }
        """
        let program = try Parser.parse(source)

        #expect(program.featureSets.count == 1)
        #expect(program.featureSets[0].name == "Application-Start")
    }
}

// MARK: - ARO Statement Parsing Tests

@Suite("ARO Statement Parsing Tests")
struct AROStatementParsingTests {

    @Test("Parses basic ARO statement")
    func testBasicAROStatement() throws {
        let source = """
        (Test: Test) {
            <Extract> the <user> from the <request>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.action.verb == "Extract")
        #expect(statement.result.base == "user")
        #expect(statement.object.preposition == .from)
        #expect(statement.object.noun.base == "request")
    }

    @Test("Parses ARO statement with qualified result")
    func testQualifiedResult() throws {
        let source = """
        (Test: Test) {
            <Extract> the <user: id.name> from the <request>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.result.base == "user")
        #expect(statement.result.specifiers == ["id", "name"])
    }

    @Test("Parses ARO statement with qualified object")
    func testQualifiedObject() throws {
        let source = """
        (Test: Test) {
            <Extract> the <data> from the <request: body>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.noun.base == "request")
        #expect(statement.object.noun.specifiers == ["body"])
    }

    @Test("Parses ARO statement with string literal")
    func testStringLiteral() throws {
        let source = """
        (Test: Test) {
            <Log> "Hello World" to the <console>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // Literals are now stored as expressions (ARO-0002)
        if let expr = statement.expression as? LiteralExpression {
            #expect(expr.value == .string("Hello World"))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses ARO statement with integer literal")
    func testIntegerLiteral() throws {
        let source = """
        (Test: Test) {
            <Start> the <server> for the <http> with 8080.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // Literals are now stored as expressions (ARO-0002)
        if let expr = statement.expression as? LiteralExpression {
            #expect(expr.value == .integer(8080))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses ARO statement with float literal")
    func testFloatLiteral() throws {
        let source = """
        (Test: Test) {
            <Set> the <timeout> for the <connection> with 3.14.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // Literals are now stored as expressions (ARO-0002)
        if let expr = statement.expression as? LiteralExpression {
            #expect(expr.value == .float(3.14))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses ARO statement with boolean literal")
    func testBooleanLiteral() throws {
        let source = """
        (Test: Test) {
            <Set> the <flag> for the <config> with true.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        // Literals are now stored as expressions (ARO-0002)
        if let expr = statement.expression as? LiteralExpression {
            #expect(expr.value == .boolean(true))
        } else {
            Issue.record("Expected LiteralExpression")
        }
    }

    @Test("Parses ARO statement with 'for' preposition")
    func testForPreposition() throws {
        let source = """
        (Test: Test) {
            <Compute> the <result> for the <input>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.preposition == .for)
    }

    @Test("Parses ARO statement with 'to' preposition")
    func testToPreposition() throws {
        let source = """
        (Test: Test) {
            <Send> the <email> to the <user>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.preposition == .to)
    }

    @Test("Parses ARO statement with 'into' preposition")
    func testIntoPreposition() throws {
        let source = """
        (Test: Test) {
            <Transform> the <data> into the <json>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.preposition == .into)
    }

    @Test("Parses ARO statement with 'via' preposition")
    func testViaPreposition() throws {
        let source = """
        (Test: Test) {
            <Fetch> the <data> via the <api>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.preposition == .via)
    }

    @Test("Parses ARO statement with 'against' preposition")
    func testAgainstPreposition() throws {
        let source = """
        (Test: Test) {
            <Validate> the <input> against the <schema>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.object.preposition == .against)
    }

    @Test("Parses multiple statements")
    func testMultipleStatements() throws {
        let source = """
        (Test: Test) {
            <Extract> the <user> from the <request>.
            <Validate> the <user> against the <schema>.
            <Return> the <response> for the <success>.
        }
        """
        let program = try Parser.parse(source)

        #expect(program.featureSets[0].statements.count == 3)
    }

    @Test("Parses compound identifiers in statements")
    func testCompoundIdentifiers() throws {
        let source = """
        (Test: Test) {
            <Extract> the <user-data> from the <http-request>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! AROStatement

        #expect(statement.result.base == "user-data")
        #expect(statement.object.noun.base == "http-request")
    }
}

// MARK: - Publish Statement Parsing Tests

@Suite("Publish Statement Parsing Tests")
struct PublishStatementParsingTests {

    @Test("Parses basic publish statement")
    func testBasicPublishStatement() throws {
        let source = """
        (Test: Test) {
            <Publish> as <external-name> <internal>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! PublishStatement

        #expect(statement.externalName == "external-name")
        #expect(statement.internalVariable == "internal")
    }

    @Test("Parses publish with simple names")
    func testPublishSimpleNames() throws {
        let source = """
        (Test: Test) {
            <Publish> as <userData> <data>.
        }
        """
        let program = try Parser.parse(source)
        let statement = program.featureSets[0].statements[0] as! PublishStatement

        #expect(statement.externalName == "userData")
        #expect(statement.internalVariable == "data")
    }
}

// MARK: - Parser Error Tests

@Suite("Parser Error Tests")
struct ParserErrorTests {

    @Test("Reports missing feature set name")
    func testMissingFeatureSetName() throws {
        let diagnostics = DiagnosticCollector()
        _ = try Parser.parse("(: Activity) { }", diagnostics: diagnostics)

        #expect(diagnostics.hasErrors)
    }

    @Test("Reports missing business activity")
    func testMissingBusinessActivity() throws {
        let diagnostics = DiagnosticCollector()
        _ = try Parser.parse("(Name:) { }", diagnostics: diagnostics)

        #expect(diagnostics.hasErrors)
    }

    @Test("Reports unexpected token")
    func testUnexpectedToken() throws {
        let diagnostics = DiagnosticCollector()
        _ = try Parser.parse("(Name: Activity) { <Extract> }", diagnostics: diagnostics)

        #expect(diagnostics.hasErrors)
    }

    @Test("Recovers from errors and continues parsing")
    func testErrorRecovery() throws {
        let source = """
        (First: One) {
            <Invalid syntax here
        }
        (Second: Two) {
            <Extract> the <data> from the <source>.
        }
        """
        let diagnostics = DiagnosticCollector()
        let program = try Parser.parse(source, diagnostics: diagnostics)

        // Should have at least one feature set despite errors
        #expect(program.featureSets.count >= 1)
    }
}

// MARK: - Parser Error Type Tests

@Suite("Parser Error Type Tests")
struct ParserErrorTypeTests {

    @Test("ParserError descriptions are correct")
    func testParserErrorDescriptions() {
        let span = SourceSpan(at: SourceLocation())
        let token = Token(kind: .identifier("test"), span: span, lexeme: "test")

        let unexpectedToken = ParserError.unexpectedToken(expected: "'('", got: token)
        #expect(unexpectedToken.message.contains("Expected"))

        let missingName = ParserError.missingFeatureSetName(at: SourceLocation())
        #expect(missingName.message.contains("Missing feature set name"))

        let missingActivity = ParserError.missingBusinessActivity(at: SourceLocation())
        #expect(missingActivity.message.contains("Missing business activity"))

        let invalidStatement = ParserError.invalidStatement(at: SourceLocation())
        #expect(invalidStatement.message.contains("Invalid statement"))

        let invalidNoun = ParserError.invalidQualifiedNoun(at: SourceLocation())
        #expect(invalidNoun.message.contains("Invalid qualified noun"))

        let emptyFeature = ParserError.emptyFeatureSet(at: SourceLocation())
        #expect(emptyFeature.message.contains("Feature set must contain"))
    }

    @Test("ParserError locations are correct")
    func testParserErrorLocations() {
        let loc = SourceLocation(line: 5, column: 10, offset: 50)
        let span = SourceSpan(at: loc)
        let token = Token(kind: .identifier("test"), span: span, lexeme: "test")

        let unexpectedToken = ParserError.unexpectedToken(expected: "'('", got: token)
        #expect(unexpectedToken.location?.line == 5)
        #expect(unexpectedToken.location?.column == 10)

        let missingName = ParserError.missingFeatureSetName(at: loc)
        #expect(missingName.location?.line == 5)
    }
}

// MARK: - AST Visitor Tests

@Suite("AST Visitor Tests")
struct ASTVisitorTests {

    @Test("ASTPrinter produces output")
    func testASTPrinter() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user> from the <request>.
        }
        """
        let program = try Parser.parse(source)
        let printer = ASTPrinter()
        let output = try program.accept(printer)

        #expect(output.contains("Program"))
        #expect(output.contains("FeatureSet"))
        #expect(output.contains("AROStatement"))
    }

    @Test("ASTPrinter formats publish statements")
    func testASTPrinterPublish() throws {
        let source = """
        (Test: Activity) {
            <Publish> as <external> <internal>.
        }
        """
        let program = try Parser.parse(source)
        let printer = ASTPrinter()
        let output = try program.accept(printer)

        #expect(output.contains("PublishStatement"))
        #expect(output.contains("External"))
        #expect(output.contains("Internal"))
    }
}

// MARK: - Diagnostic Tests

@Suite("Diagnostic Tests")
struct DiagnosticTests {

    @Test("DiagnosticCollector collects errors")
    func testDiagnosticCollectorErrors() {
        let collector = DiagnosticCollector()

        collector.error("Test error")
        #expect(collector.hasErrors)
        #expect(collector.errors.count == 1)
    }

    @Test("DiagnosticCollector collects warnings")
    func testDiagnosticCollectorWarnings() {
        let collector = DiagnosticCollector()

        collector.warning("Test warning")
        #expect(!collector.hasErrors)
        #expect(collector.warnings.count == 1)
    }

    @Test("DiagnosticCollector collects notes")
    func testDiagnosticCollectorNotes() {
        let collector = DiagnosticCollector()

        collector.note("Test note")
        #expect(!collector.hasErrors)
        #expect(collector.diagnostics.count == 1)
    }

    @Test("Diagnostic description includes all info")
    func testDiagnosticDescription() {
        let loc = SourceLocation(line: 1, column: 1, offset: 0)
        let diagnostic = Diagnostic(
            severity: .error,
            message: "Test message",
            location: loc,
            hints: ["Try this"]
        )

        let desc = diagnostic.description
        #expect(desc.contains("error"))
        #expect(desc.contains("Test message"))
        #expect(desc.contains("hint"))
    }

    @Test("Diagnostic created from CompilerError")
    func testDiagnosticFromError() {
        let error = ParserError.missingFeatureSetName(at: SourceLocation())
        let diagnostic = Diagnostic.from(error)

        #expect(diagnostic.severity == .error)
        #expect(diagnostic.message.contains("Missing feature set name"))
    }
}

// MARK: - Source Location Tests

@Suite("Source Location Tests")
struct SourceLocationTests {

    @Test("SourceLocation default values")
    func testSourceLocationDefaults() {
        let loc = SourceLocation()
        #expect(loc.line == 1)
        #expect(loc.column == 1)
        #expect(loc.offset == 0)
    }

    @Test("SourceLocation custom values")
    func testSourceLocationCustom() {
        let loc = SourceLocation(line: 10, column: 5, offset: 100)
        #expect(loc.line == 10)
        #expect(loc.column == 5)
        #expect(loc.offset == 100)
    }

    @Test("SourceSpan creation")
    func testSourceSpanCreation() {
        let start = SourceLocation(line: 1, column: 1, offset: 0)
        let end = SourceLocation(line: 1, column: 10, offset: 9)
        let span = SourceSpan(start: start, end: end)

        #expect(span.start.column == 1)
        #expect(span.end.column == 10)
    }

    @Test("SourceSpan at location")
    func testSourceSpanAtLocation() {
        let loc = SourceLocation(line: 5, column: 3, offset: 50)
        let span = SourceSpan(at: loc)

        #expect(span.start == loc)
        #expect(span.end == loc)
    }

    @Test("SourceSpan merging")
    func testSourceSpanMerging() {
        let span1 = SourceSpan(
            start: SourceLocation(line: 1, column: 1, offset: 0),
            end: SourceLocation(line: 1, column: 5, offset: 4)
        )
        let span2 = SourceSpan(
            start: SourceLocation(line: 1, column: 10, offset: 9),
            end: SourceLocation(line: 1, column: 15, offset: 14)
        )

        let merged = span1.merged(with: span2)
        #expect(merged.start.column == 1)
        #expect(merged.end.column == 15)
    }
}
