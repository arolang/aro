// ============================================================
// StaticAnalysisTests.swift
// ARO Parser - Static Analysis Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Duplicate Feature Set Tests

@Suite("Duplicate Feature Set Detection")
struct DuplicateFeatureSetTests {

    @Test("No error when feature set names are unique")
    func testUniqueNames() throws {
        let source = """
        (Feature One: API) {
            Return an <OK: status> for the <result>.
        }

        (Feature Two: API) {
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let duplicateErrors = diagnostics.errors.filter { $0.message.contains("Duplicate feature set") }
        #expect(duplicateErrors.isEmpty)
    }

    @Test("Error when duplicate feature set names")
    func testDuplicateNames() throws {
        let source = """
        (Same Name: API) {
            Return an <OK: status> for the <result>.
        }

        (Same Name: API) {
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let duplicateErrors = diagnostics.errors.filter { $0.message.contains("Duplicate feature set") }
        #expect(duplicateErrors.count == 1)
        #expect(duplicateErrors[0].message.contains("Same Name"))
    }

    @Test("Multiple duplicates reported separately")
    func testMultipleDuplicates() throws {
        let source = """
        (Same Name: API) {
            Return an <OK: status> for the <result>.
        }

        (Same Name: API) {
            Return an <OK: status> for the <result>.
        }

        (Same Name: API) {
            Return an <OK: status> for the <result>.
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        let duplicateErrors = result.diagnostics.filter { $0.message.contains("Duplicate feature set") }
        #expect(duplicateErrors.count == 2)  // Second and third are duplicates
    }
}

// MARK: - Empty Feature Set Tests

@Suite("Empty Feature Set Detection")
struct EmptyFeatureSetTests {

    @Test("Parser error for empty feature set")
    func testEmptyFeatureSet() throws {
        // Empty feature sets are rejected at the parser level, not semantic analysis
        let source = """
        (Empty Feature: API) {
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        // Parser should report an error for empty feature sets
        // The exact error depends on parser behavior - it should fail compilation
        #expect(result.hasErrors)
    }

    @Test("No warning for non-empty feature set")
    func testNonEmptyFeatureSet() throws {
        let source = """
        (Non Empty: API) {
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let emptyWarnings = diagnostics.warnings.filter { $0.message.contains("has no statements") }
        #expect(emptyWarnings.isEmpty)
    }
}

// MARK: - Unreachable Code Tests

@Suite("Unreachable Code Detection")
struct UnreachableCodeTests {

    @Test("Warning for code after Return")
    func testCodeAfterReturn() throws {
        let source = """
        (Test Feature: API) {
            Return an <OK: status> for the <result>.
            Log <message> to the <console>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let unreachableWarnings = diagnostics.warnings.filter { $0.message.contains("Unreachable code") }
        #expect(unreachableWarnings.count == 1)
    }

    @Test("Warning for code after Throw")
    func testCodeAfterThrow() throws {
        let source = """
        (Test Feature: API) {
            Throw a <Failure: status> for the <operation>.
            Log <message> to the <console>.
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        let unreachableWarnings = result.diagnostics.filter { $0.message.contains("Unreachable code") }
        #expect(unreachableWarnings.count == 1)
    }

    @Test("No warning when Return is last statement")
    func testReturnAtEnd() throws {
        let source = """
        (Test Feature: API) {
            Log <message> to the <console>.
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let unreachableWarnings = diagnostics.warnings.filter { $0.message.contains("Unreachable code") }
        #expect(unreachableWarnings.isEmpty)
    }
}

// MARK: - Missing Return Tests

@Suite("Missing Return Detection")
struct MissingReturnTests {

    @Test("Warning for missing Return statement")
    func testMissingReturn() throws {
        let source = """
        (Test Feature: API) {
            Log <message> to the <console>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let missingReturnWarnings = diagnostics.warnings.filter { $0.message.contains("no Return") }
        #expect(missingReturnWarnings.count == 1)
    }

    @Test("No warning when Return is present")
    func testReturnPresent() throws {
        let source = """
        (Test Feature: API) {
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let missingReturnWarnings = diagnostics.warnings.filter { $0.message.contains("no Return") }
        #expect(missingReturnWarnings.isEmpty)
    }

    @Test("No warning when Throw is present")
    func testThrowPresent() throws {
        let source = """
        (Test Feature: API) {
            Throw an <Error: status> for the <failure>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let missingReturnWarnings = diagnostics.warnings.filter { $0.message.contains("no Return") }
        #expect(missingReturnWarnings.isEmpty)
    }
}

// MARK: - Orphaned Event Tests

@Suite("Orphaned Event Detection")
struct OrphanedEventTests {

    @Test("Warning when emitting event with no handler")
    func testOrphanedEvent() throws {
        let source = """
        (Create User: API) {
            Emit a <UserCreated: event> with <user>.
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let orphanedWarnings = diagnostics.warnings.filter { $0.message.contains("no handler exists") }
        #expect(orphanedWarnings.count == 1)
        #expect(orphanedWarnings[0].message.contains("UserCreated"))
    }

    @Test("No warning when handler exists")
    func testHandlerExists() throws {
        let source = """
        (Create User: API) {
            Emit a <UserCreated: event> with <user>.
            Return an <OK: status> for the <result>.
        }

        (Log User: UserCreated Handler) {
            Log <message> to the <console>.
            Return an <OK: status> for the <log>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let orphanedWarnings = diagnostics.warnings.filter { $0.message.contains("no handler exists") }
        #expect(orphanedWarnings.isEmpty)
    }

    @Test("Multiple orphaned events reported")
    func testMultipleOrphaned() throws {
        let source = """
        (Test Feature: API) {
            Emit a <EventOne: event> for the <trigger>.
            Emit a <EventTwo: event> for the <trigger>.
            Return an <OK: status> for the <result>.
        }
        """
        let diagnostics = DiagnosticCollector()
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        let orphanedWarnings = diagnostics.warnings.filter { $0.message.contains("no handler exists") }
        #expect(orphanedWarnings.count == 2)
    }
}

// MARK: - Integration Tests

@Suite("Static Analysis Integration")
struct StaticAnalysisIntegrationTests {

    @Test("All checks work together with full compilation")
    func testAllChecksWithCompiler() throws {
        let source = """
        (Good Feature: API) {
            Extract the <data> from the <request>.
            Create the <user> with <data>.
            Emit a <UserCreated: event> with <user>.
            Return an <OK: status> for the <user>.
        }

        (Handle User: UserCreated Handler) {
            Log <message> to the <console>.
            Return an <OK: status> for the <handler>.
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        // Should compile successfully with no errors
        #expect(result.isSuccess)
        #expect(!result.hasErrors)
    }

    @Test("Bad code triggers multiple warnings")
    func testBadCodeWarnings() throws {
        let source = """
        (Bad Feature: API) {
            Log <message> to the <console>.
            Emit a <OrphanEvent: event> for the <trigger>.
        }
        """
        let compiler = Compiler()
        let result = compiler.compile(source)

        // Should have warnings for missing return and orphaned event
        let warnings = result.diagnostics.filter { $0.severity == .warning }
        #expect(warnings.count >= 2)
    }
}
