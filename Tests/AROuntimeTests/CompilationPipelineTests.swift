// ============================================================
// CompilationPipelineTests.swift
// ARO Runtime - Compilation Pipeline Integration Tests (#220)
//
// Tests the same pipeline used by CompileCommand, CheckCommand,
// and BuildCommand: source → lex → parse → analyze.
// ============================================================

import Foundation
import Testing
@testable import AROParser
@testable import ARORuntime

// MARK: - Single-File Compilation Tests

@Suite("Single-File Compilation Tests")
struct SingleFileCompilationTests {

    @Test("Compiles minimal Application-Start")
    func testMinimalAppStart() {
        let source = """
        (Application-Start: Hello) {
            Log "Hello" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "Should compile without errors: \(errors.map(\.message))")
        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 1)
    }

    @Test("Compiles multiple feature sets")
    func testMultipleFeatureSets() {
        let source = """
        (Application-Start: App) {
            Log "Starting" to the <console>.
            Emit a <Ready: event> with <startup>.
            Return an <OK: status> for the <startup>.
        }

        (Handle Event: Ready Handler) {
            Log "Ready" to the <console>.
            Return an <OK: status> for the <event>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
        #expect(result.program.featureSets.count == 2)
    }

    @Test("Reports syntax errors")
    func testSyntaxErrors() {
        let source = """
        (Application-Start: Bad) {
            Extract the from the <source>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(!errors.isEmpty, "Should report syntax errors")
    }

    @Test("Reports missing feature set name")
    func testMissingFeatureSetName() {
        let source = """
        (: Business) {
            Log "test" to the <console>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(!errors.isEmpty)
    }

    @Test("Handles empty source")
    func testEmptySource() {
        let result = Compiler().compile("")
        // Empty source has no feature sets but should not crash
        #expect(result.program.featureSets.isEmpty == true)
    }

    @Test("Handles comment-only source")
    func testCommentOnlySource() {
        let source = """
        (* This is a comment *)
        (* Another comment *)
        """
        let result = Compiler().compile(source)
        #expect(result.program.featureSets.isEmpty == true)
    }
}

// MARK: - Semantic Analysis Tests

@Suite("Semantic Analysis Tests")
struct SemanticAnalysisTests {

    @Test("Produces analyzed program with symbol tables")
    func testAnalyzedProgram() {
        let source = """
        (Application-Start: Test) {
            Extract the <user> from the <request: body>.
            Compute the <greeting> from "Hello".
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        #expect(result.isSuccess)
        #expect(result.analyzedProgram.featureSets.count == 1)

        let analyzed = result.analyzedProgram.featureSets.first
        #expect(analyzed?.symbolTable != nil)
    }

    @Test("Symbol table contains defined variables")
    func testSymbolTableContents() {
        let source = """
        (Application-Start: Test) {
            Extract the <user> from the <request: body>.
            Compute the <greeting> for the <user>.
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let analyzed = result.analyzedProgram.featureSets.first
        let symbols = analyzed?.symbolTable

        #expect(symbols?.contains("user") == true)
        #expect(symbols?.contains("greeting") == true)
    }

    @Test("Data flow analysis produces flows")
    func testDataFlowAnalysis() {
        let source = """
        (Application-Start: Test) {
            Extract the <data> from the <request: body>.
            Compute the <result> from the <data>.
            Return an <OK: status> with <result>.
        }
        """
        let result = Compiler().compile(source)
        let analyzed = result.analyzedProgram.featureSets.first

        #expect(analyzed?.dataFlows != nil)
        // data flows from Extract to Compute to Return
        #expect(analyzed!.dataFlows.count >= 1)
    }
}

// MARK: - Diagnostic Collection Tests

@Suite("Diagnostic Collection Tests")
struct DiagnosticCollectionTests {

    @Test("DiagnosticCollector accumulates diagnostics")
    func testDiagnosticAccumulation() {
        let collector = DiagnosticCollector()
        collector.error("Error 1", at: SourceLocation())
        collector.warning("Warning 1", at: SourceLocation())
        collector.note("Note 1", at: SourceLocation())

        #expect(collector.diagnostics.count == 3)
        #expect(collector.hasErrors == true)
    }

    @Test("DiagnosticCollector clears on new compilation")
    func testDiagnosticClearing() {
        let compiler = Compiler()

        // First compile with error
        let _ = compiler.compile("invalid syntax {{{")

        // Second compile should not carry over diagnostics
        let result = compiler.compile("""
        (Application-Start: Clean) {
            Return an <OK: status> for the <startup>.
        }
        """)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "Second compilation should not have errors from first")
    }

    @Test("Diagnostics include source locations")
    func testDiagnosticLocations() {
        let source = """
        (Application-Start: Test) {
            Extract the from the <source>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }

        for error in errors {
            if let loc = error.location {
                #expect(loc.line >= 1)
                #expect(loc.column >= 1)
            }
        }
    }
}

// MARK: - Multi-File Compilation Tests

@Suite("Multi-File Application Discovery Tests")
struct MultiFileDiscoveryTests {

    @Test("ApplicationDiscovery finds .aro files in directory")
    func testDiscoverDirectory() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create test .aro files
        try """
        (Application-Start: Test App) {
            Return an <OK: status> for the <startup>.
        }
        """.write(to: tempDir.appendingPathComponent("main.aro"), atomically: true, encoding: .utf8)

        try """
        (Handle Users: listUsers) {
            Return an <OK: status> for the <users>.
        }
        """.write(to: tempDir.appendingPathComponent("users.aro"), atomically: true, encoding: .utf8)

        let discovery = ApplicationDiscovery()
        let app = try await discovery.discover(at: tempDir)

        #expect(app.sourceFiles.count == 2)
        #expect(app.rootPath == tempDir)
    }

    @Test("ApplicationDiscovery handles single file")
    func testDiscoverSingleFile() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("single.aro")
        try """
        (Application-Start: Single) {
            Return an <OK: status> for the <startup>.
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        let discovery = ApplicationDiscovery()
        let app = try await discovery.discover(at: file)

        #expect(app.sourceFiles.count == 1)
    }

    @Test("ApplicationDiscovery throws for missing path")
    func testDiscoverMissing() async {
        let discovery = ApplicationDiscovery()
        let bogusPath = URL(fileURLWithPath: "/nonexistent/path/to/app")

        do {
            _ = try await discovery.discover(at: bogusPath)
            Issue.record("Should have thrown for missing path")
        } catch {
            // Expected
        }
    }

    @Test("ApplicationDiscovery detects openapi.yaml")
    func testDiscoverOpenAPI() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        (Application-Start: API) {
            Return an <OK: status> for the <startup>.
        }
        """.write(to: tempDir.appendingPathComponent("main.aro"), atomically: true, encoding: .utf8)

        try """
        openapi: 3.0.3
        info:
          title: Test API
          version: 1.0.0
        paths: {}
        """.write(to: tempDir.appendingPathComponent("openapi.yaml"), atomically: true, encoding: .utf8)

        let discovery = ApplicationDiscovery()
        let app = try await discovery.discover(at: tempDir)

        #expect(app.hasOpenAPIContract == true)
        #expect(app.openAPISpec != nil)
    }

    @Test("ApplicationDiscovery discovers .store files")
    func testDiscoverStoreFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try """
        (Application-Start: Store App) {
            Return an <OK: status> for the <startup>.
        }
        """.write(to: tempDir.appendingPathComponent("main.aro"), atomically: true, encoding: .utf8)

        try """
        - name: Alice
          age: 30
        - name: Bob
          age: 25
        """.write(to: tempDir.appendingPathComponent("users.store"), atomically: true, encoding: .utf8)

        let discovery = ApplicationDiscovery()
        let app = try await discovery.discover(at: tempDir)

        #expect(app.storeFiles.count == 1)
    }
}

// MARK: - Compile Report Tests

@Suite("Compile Report Tests")
struct CompileReportTests {

    @Test("compileWithReport produces text output")
    func testCompileWithReport() {
        let source = """
        (Application-Start: Report Test) {
            Log "Hello" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let compiler = Compiler()
        let report = compiler.compileWithReport(source)

        #expect(!report.isEmpty)
        #expect(report.contains("Application-Start") || report.contains("Report Test"))
    }

    @Test("compileWithReport includes errors for bad source")
    func testCompileWithReportErrors() {
        let compiler = Compiler()
        let report = compiler.compileWithReport("this is not valid aro code {{{")

        #expect(!report.isEmpty)
        // Report should mention errors
        #expect(report.lowercased().contains("error") || report.contains("unexpected"))
    }
}

// MARK: - Control Flow Compilation Tests

@Suite("Control Flow Compilation Tests")
struct ControlFlowCompilationTests {

    @Test("ForEach loop compiles")
    func testForEachLoop() {
        let source = """
        (Application-Start: Loop Test) {
            Extract the <items> from the <request: body>.
            For each <item> in <items> {
                Log <item> to the <console>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Nested ForEach loops compile")
    func testNestedForEach() {
        let source = """
        (Application-Start: Nested) {
            Extract the <rows> from the <request: body>.
            For each <row> in <rows> {
                Extract the <cells> from the <row: cells>.
                For each <cell> in <cells> {
                    Log <cell> to the <console>.
                }
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Match statement compiles")
    func testMatchStatement() {
        let source = """
        (Application-Start: Match Test) {
            Create the <method> with "GET".
            match <method> {
                case "GET" {
                    Log "GET" to the <console>.
                }
                case "POST" {
                    Log "POST" to the <console>.
                }
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("When guard compiles")
    func testWhenGuard() {
        let source = """
        (Application-Start: Conditional Demo) {
            Create the <role> with "admin".
            Log "Admin access" to the <console> when <role> == "admin".
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Range loop compiles")
    func testRangeLoop() {
        let source = """
        (Application-Start: Range Test) {
            For <i> from 1 to 10 {
                Log <i> to the <console>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Break in loop compiles")
    func testBreakInLoop() {
        let source = """
        (Application-Start: Loop Exit Demo) {
            Extract the <items> from the <request: body>.
            For each <item> in <items> {
                Log <item> to the <console>.
                Break.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Publish statement compiles")
    func testPublishStatement() {
        let source = """
        (Application-Start: Sharing Demo) {
            Compute the <value> from "hello".
            Publish as <global-value> <value>.
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }
}
