// ============================================================
// StatementCodeGenTests.swift
// AROCompiler Tests - Statement-level IR Generation (#220)
// ============================================================

import XCTest
@testable import AROCompiler
@testable import AROParser

#if !os(Windows)

/// Tests that each supported statement type generates valid LLVM IR.
/// Uses the full pipeline: source → parse → analyze → codegen.
final class StatementCodeGenTests: XCTestCase {

    // MARK: - Helpers

    /// Compile ARO source all the way to LLVM IR text.
    private func generateIR(_ source: String, file: StaticString = #file, line: UInt = #line) throws -> String {
        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        guard errors.isEmpty else {
            XCTFail("Compilation failed with \(errors.count) error(s): \(errors.map(\.message).joined(separator: "; "))",
                    file: file, line: line)
            return ""
        }

        let generator = LLVMCodeGenerator()
        let genResult = try generator.generate(program: result.analyzedProgram)
        return genResult.irText
    }

    // MARK: - Basic Action Statement

    func testLogActionGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Log "Hello World" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("main"), "IR should contain main function")
        XCTAssertTrue(ir.contains("aro_action_log") || ir.contains("action_log"),
                      "IR should contain log action call")
    }

    func testExtractActionGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Extract the <name> from the <request: body>.
            Log <name> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("aro_action_extract") || ir.contains("action_extract"),
                      "IR should contain extract action call")
    }

    func testComputeActionGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Compute the <total> from 2 + 3.
            Log <total> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("aro_action_compute") || ir.contains("action_compute"),
                      "IR should contain compute action call")
    }

    // MARK: - ForEach Loop

    func testForEachLoopGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Extract the <items> from the <request: body>.
            For each <item> in <items> {
                Log <item> to the <console>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        // Loop should generate branch/label instructions
        XCTAssertTrue(ir.contains("br ") || ir.contains("loop"),
                      "ForEach loop should generate branch instructions")
    }

    // MARK: - Range Loop

    func testRangeLoopGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            For <i> from 1 to 5 {
                Log <i> to the <console>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("br ") || ir.contains("loop") || ir.contains("icmp"),
                      "Range loop should generate comparison and branch instructions")
    }

    // MARK: - Match Statement

    func testMatchStatementGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Create the <method> with "GET".
            match <method> {
                case "GET" {
                    Log "GET request" to the <console>.
                }
                case "POST" {
                    Log "POST request" to the <console>.
                }
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        // Match generates branching logic
        XCTAssertTrue(ir.contains("br ") || ir.contains("switch"),
                      "Match statement should generate branching instructions")
    }

    // MARK: - Break Statement

    func testBreakStatementIsRegistered() throws {
        // Break is registered in the statement dispatch table
        // (full IR generation may fail if break is outside a loop context,
        // but the statement type must be recognized by the code generator)
        XCTAssertTrue(
            LLVMCodeGenerator.supportedStatementTypeIdentifiers.contains(ObjectIdentifier(BreakStatement.self)),
            "BreakStatement should be in the supported statement types"
        )
    }

    // MARK: - Publish Statement

    func testPublishStatementGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Compute the <greeting> from "Hello".
            Publish as <global-greeting> <greeting>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("aro_variable_publish") || ir.contains("variable_publish") || ir.contains("global"),
                      "Publish statement should generate variable publish call or global reference")
    }

    // MARK: - While Loop

    func testWhileLoopGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Compute the <counter> from 0.
            While <counter> < 10 {
                Compute the <counter> from <counter> + 1.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("br ") || ir.contains("icmp"),
                      "While loop should generate comparison and branch instructions")
    }

    // MARK: - Multiple Feature Sets

    func testMultipleFeatureSetsGenerateIR() throws {
        let source = """
        (Application-Start: Multi Feature) {
            Log "Starting" to the <console>.
            Emit a <Ready: event> with <startup>.
            Return an <OK: status> for the <startup>.
        }

        (Handle Ready: Ready Handler) {
            Log "Ready event received" to the <console>.
            Return an <OK: status> for the <event>.
        }
        """
        let ir = try generateIR(source)
        // Should generate functions for both feature sets
        XCTAssertTrue(ir.contains("multi_feature") || ir.contains("application_start"),
                      "Should contain Application-Start function")
        XCTAssertTrue(ir.contains("ready_handler") || ir.contains("handle_ready"),
                      "Should contain event handler function")
    }

    // MARK: - Nested Loops

    func testNestedForEachLoopsGenerateIR() throws {
        let source = """
        (Application-Start: Test App) {
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
        let ir = try generateIR(source)
        // Nested loops should generate multiple loop structures
        // Count branch instructions — nested loops need at least 4 (2 condition + 2 back-edge)
        let branchCount = ir.components(separatedBy: "br ").count - 1
        XCTAssertGreaterThanOrEqual(branchCount, 4,
                                     "Nested loops should generate at least 4 branch instructions")
    }

    // MARK: - Require Statement

    func testRequireStatementGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Require the <config> from the <environment>.
            Log <config> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("aro_action_extract") || ir.contains("action_extract") || ir.contains("require"),
                      "Require statement should generate extraction or require call")
    }

    // MARK: - Empty Feature Set

    func testEmptyFeatureSetBody() throws {
        let source = """
        (Application-Start: Minimal) {
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("main"), "Minimal program should still have main function")
    }

    // MARK: - String Literals

    func testStringLiteralsInIR() throws {
        let source = """
        (Application-Start: Test App) {
            Log "Hello, ARO!" to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        XCTAssertTrue(ir.contains("Hello, ARO!") || ir.contains("Hello\\2C ARO!"),
                      "IR should contain the string literal (possibly escaped)")
    }

    // MARK: - Conditional (When Guard)

    func testWhenGuardGeneratesIR() throws {
        let source = """
        (Application-Start: Test App) {
            Create the <role> with "admin".
            Log "Admin access" to the <console> when <role> == "admin".
            Return an <OK: status> for the <startup>.
        }
        """
        let ir = try generateIR(source)
        // When guard on a statement generates conditional branching
        XCTAssertTrue(ir.contains("br ") || ir.contains("icmp"),
                      "When guard should generate conditional branch")
    }
}

#endif
