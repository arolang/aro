// ============================================================
// CompilerTests.swift
// ARO Parser - Comprehensive Compiler Unit Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Compilation Result Tests

@Suite("Compilation Result Tests")
struct CompilationResultTests {

    @Test("Successful compilation has no errors")
    func testSuccessfulCompilation() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess == true)
        #expect(result.hasErrors == false)
    }

    @Test("Failed compilation has errors")
    func testFailedCompilation() {
        let source = "invalid source {"
        let result = Compiler.compile(source)

        #expect(result.isSuccess == false)
        #expect(result.hasErrors == true)
    }

    @Test("Compilation result contains program")
    func testCompilationResultProgram() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.program.featureSets.count == 1)
    }

    @Test("Compilation result contains analyzed program")
    func testCompilationResultAnalyzedProgram() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.analyzedProgram.featureSets.count == 1)
    }

    @Test("Compilation result contains diagnostics")
    func testCompilationResultDiagnostics() {
        let source = """
        (Test: Testing) {
            <Publish> as <ext> <undefined>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.diagnostics.count > 0)
    }
}

// MARK: - Compiler Pipeline Tests

@Suite("Compiler Pipeline Tests")
struct CompilerPipelineTests {

    @Test("Compiler processes empty source")
    func testEmptySource() {
        let result = Compiler.compile("")

        #expect(result.isSuccess)
        #expect(result.program.featureSets.isEmpty)
    }

    @Test("Compiler processes single feature set")
    func testSingleFeatureSet() {
        let source = """
        (User Auth: Security) {
            <Extract> the <user> from the <request>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 1)
        #expect(result.program.featureSets[0].name == "User Auth")
    }

    @Test("Compiler processes multiple feature sets")
    func testMultipleFeatureSets() {
        let source = """
        (First: One) {
            <Extract> the <a> from the <request>.
        }
        (Second: Two) {
            <Extract> the <b> from the <request>.
        }
        (Third: Three) {
            <Extract> the <c> from the <request>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 3)
    }

    @Test("Compiler processes statements")
    func testStatementProcessing() {
        let source = """
        (Test: Testing) {
            <Extract> the <user> from the <request>.
            <Validate> the <user> against the <schema>.
            <Return> the <response> for the <success>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets[0].statements.count == 3)
    }

    @Test("Compiler processes publish statements")
    func testPublishProcessing() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
            <Publish> as <external-data> <data>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.analyzedProgram.featureSets[0].exports.contains("external-data"))
    }

    @Test("Compiler tracks symbol tables")
    func testSymbolTableTracking() {
        let source = """
        (Test: Testing) {
            <Extract> the <user: identifier> from the <request>.
            <Compute> the <hash> for the <user>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        let symbolTable = result.analyzedProgram.featureSets[0].symbolTable
        #expect(symbolTable.lookup("user") != nil)
        #expect(symbolTable.lookup("hash") != nil)
    }

    @Test("Compiler tracks data flow")
    func testDataFlowTracking() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <source>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        let dataFlow = result.analyzedProgram.featureSets[0].dataFlows[0]
        #expect(dataFlow.outputs.contains("data"))
    }

    @Test("Compiler registers global symbols")
    func testGlobalSymbolRegistration() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
            <Publish> as <published-data> <data>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        let lookup = result.analyzedProgram.globalRegistry.lookup("published-data")
        #expect(lookup != nil)
    }
}

// MARK: - Compiler Error Handling Tests

@Suite("Compiler Error Handling Tests")
struct CompilerErrorHandlingTests {

    @Test("Compiler handles lexer errors")
    func testLexerErrorHandling() {
        let source = "\"unterminated string"
        let result = Compiler.compile(source)

        #expect(result.hasErrors)
        #expect(result.diagnostics.contains { $0.message.contains("Unterminated") })
    }

    @Test("Compiler handles parser errors")
    func testParserErrorHandling() {
        let source = "(: Activity) { }"
        let result = Compiler.compile(source)

        #expect(result.hasErrors)
    }

    @Test("Compiler handles semantic errors")
    func testSemanticErrorHandling() {
        let source = """
        (Test: Testing) {
            <Publish> as <ext> <undefined-var>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.diagnostics.count > 0)
    }

    @Test("Compiler produces empty program on failure")
    func testFailedCompilationEmptyProgram() {
        let source = "\"unterminated"
        let result = Compiler.compile(source)

        #expect(result.program.featureSets.isEmpty)
        #expect(result.analyzedProgram.featureSets.isEmpty)
    }

    @Test("Compiler collects multiple diagnostics")
    func testMultipleDiagnostics() {
        let source = """
        (Test: Testing) {
            <Publish> as <a> <undefined1>.
            <Publish> as <b> <undefined2>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.diagnostics.count >= 2)
    }
}

// MARK: - Compiler Report Tests

@Suite("Compiler Report Tests")
struct CompilerReportTests {

    @Test("Report includes success status")
    func testReportSuccess() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("Compilation successful"))
    }

    @Test("Report includes failure status")
    func testReportFailure() {
        let source = "\"unterminated"
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("Compilation failed"))
    }

    @Test("Report includes AST summary")
    func testReportASTSummary() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("AST Summary"))
        #expect(report.contains("Feature Sets"))
    }

    @Test("Report includes symbol tables")
    func testReportSymbolTables() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("Symbol Tables"))
    }

    @Test("Report includes data flow analysis")
    func testReportDataFlow() {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("Data Flow Analysis"))
    }

    @Test("Report includes diagnostics when present")
    func testReportDiagnostics() {
        let source = """
        (Test: Testing) {
            <Publish> as <ext> <undefined>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("Diagnostics"))
    }

    @Test("Report shows feature set details")
    func testReportFeatureSetDetails() {
        let source = """
        (User Auth: Security) {
            <Extract> the <user> from the <request>.
        }
        """
        let report = Compiler.compileWithReport(source)

        #expect(report.contains("User Auth"))
        #expect(report.contains("Security"))
    }
}

// MARK: - Compiler Instance Tests

@Suite("Compiler Instance Tests")
struct CompilerInstanceTests {

    @Test("Compiler instance can be created")
    func testCompilerCreation() {
        let compiler = Compiler()
        let result = compiler.compile("")

        #expect(result.isSuccess)
    }

    @Test("Compiler instance compiles source")
    func testCompilerInstanceCompile() {
        let compiler = Compiler()
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let result = compiler.compile(source)

        #expect(result.isSuccess)
    }

    @Test("Compiler instance generates report")
    func testCompilerInstanceReport() {
        let compiler = Compiler()
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let report = compiler.compileWithReport(source)

        #expect(report.contains("ARO Compilation Report"))
    }

    @Test("Static compile method works")
    func testStaticCompile() {
        let result = Compiler.compile("")
        #expect(result.isSuccess)
    }

    @Test("Static compileWithReport method works")
    func testStaticCompileWithReport() {
        let report = Compiler.compileWithReport("")
        #expect(report.contains("ARO Compilation Report"))
    }
}

// MARK: - Full Pipeline Integration Tests

@Suite("Full Pipeline Integration Tests")
struct FullPipelineIntegrationTests {

    @Test("Complete application compilation")
    func testCompleteApplication() {
        let source = """
        (Application-Start: Entry Point) {
            <Log> the <startup: message> for the <console>.
            <Return> an <OK: status> for the <startup>.
        }

        (Get Users: User API) {
            <Retrieve> the <users> from the <user-repository>.
            <Return> an <OK: status> with <users>.
        }

        (Create User: User Creation) {
            <Extract> the <user-data> from the <request: body>.
            <Validate> the <user-data> against the <user-schema>.
            <Store> the <user> into the <user-repository>.
            <Return> a <Created: status> with <user>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 3)
    }

    @Test("Event handler compilation")
    func testEventHandlerCompilation() {
        let source = """
        (Send Notification: UserCreated Handler) {
            <Extract> the <user> from the <event: user>.
            <Send> the <notification> to the <user: email>.
            <Return> an <OK: status> for the <notification>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets[0].businessActivity == "UserCreated Handler")
    }

    @Test("Cross-feature set publishing")
    func testCrossFeatureSetPublishing() {
        let source = """
        (Auth: Security) {
            <Extract> the <user> from the <request>.
            <Publish> as <authenticated-user> <user>.
        }

        (Logging: Audit) {
            <Log> the <action> for the <authenticated-user>.
            <Return> an <OK: status> for the <log>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.analyzedProgram.globalRegistry.lookup("authenticated-user") != nil)
    }

    @Test("Complex data flow analysis")
    func testComplexDataFlow() {
        let source = """
        (Test: Testing) {
            <Extract> the <input> from the <request>.
            <Parse> the <json> from the <input>.
            <Validate> the <json> against the <schema>.
            <Transform> the <data> into the <output>.
            <Return> the <response> for the <success>.
        }
        """
        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.analyzedProgram.featureSets[0].dataFlows.count == 5)
    }
}
