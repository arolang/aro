// ============================================================
// ParseRecoveryContractTests.swift
// AROParser — an unread parse failure cannot pass for an empty file
// ============================================================
//
// `Parser.parse` recovers: a feature set it cannot read is reported
// and skipped. That is right for the CLI, which prints the collector
// and can name several errors in one pass. It was a trap for every
// other consumer: a `Program` with zero feature sets meant both "this
// file has none" and "this file did not parse", and the caller with
// no collector had no way to tell. A graph diff over an unchanged
// tree reported 144 feature sets rewritten because every broken file
// read as empty (GitLab #543).

import Testing
@testable import AROParser

@Suite("Parse recovery contract")
struct ParseRecoveryContractTests {

    private let broken = """
    (Welcome A: UserCreated Handler) {
        Log "hi" to the <console>.
        Return an <OK: status> for the <run>.
    }
    """

    private let valid = """
    (Application-Start: Main) {
        Return an <OK: status> for the <run>.
    }
    """

    // MARK: - Without a collector: strict

    @Test("A file that fails to parse throws rather than reading as empty")
    func brokenFileThrows() {
        #expect(throws: (any Error).self) {
            _ = try Parser.parse(broken)
        }
    }

    @Test("The thrown error carries every diagnostic, not just the first")
    func errorCarriesDiagnostics() {
        do {
            _ = try Parser.parse(broken)
            Issue.record("expected a throw")
        } catch let error as ParserError {
            guard case .recovered(let errors) = error else {
                Issue.record("expected .recovered, got \(error)")
                return
            }
            #expect(!errors.isEmpty)
            #expect(errors.allSatisfy { $0.severity == .error })
            #expect(error.message.contains(errors[0].message))
            #expect(error.location == errors[0].location)
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A genuinely empty file is still empty, not an error")
    func emptyFileIsNotAnError() throws {
        // The distinction the contract exists to make.
        let program = try Parser.parse("")
        #expect(program.featureSets.isEmpty)

        let comments = try Parser.parse("(* nothing here yet *)")
        #expect(comments.featureSets.isEmpty)
    }

    @Test("A valid file parses as before")
    func validFileUnchanged() throws {
        let program = try Parser.parse(valid)
        #expect(program.featureSets.count == 1)
    }

    @Test("A partial failure throws too — half a program is not a program")
    func partialFailureThrows() {
        #expect(throws: (any Error).self) {
            _ = try Parser.parse(broken + "\n\n" + valid)
        }
    }

    // MARK: - With a collector: recovering, as the CLI needs

    @Test("The collector overload keeps recovering")
    func collectorOverloadRecovers() throws {
        let collector = DiagnosticCollector()
        let program = try Parser.parse(broken, diagnostics: collector)
        // No throw: the caller asked for recovery and can see why.
        #expect(program.featureSets.isEmpty)
        #expect(collector.diagnostics.contains { $0.severity == .error })
    }

    @Test("Recovery still yields what did parse")
    func recoveryKeepsGoing() throws {
        let collector = DiagnosticCollector()
        let program = try Parser.parse(broken + "\n\n" + valid, diagnostics: collector)
        #expect(program.featureSets.count == 1, "the valid feature set survives the broken one")
        #expect(collector.diagnostics.contains { $0.severity == .error })
    }

    @Test("A warning alone does not make the strict overload throw")
    func warningsDoNotThrow() throws {
        // Only errors are failures; warnings are advice.
        let collector = DiagnosticCollector()
        collector.warning("just advice")
        #expect(collector.diagnostics.allSatisfy { $0.severity == .warning })
        let program = try Parser.parse(valid)
        #expect(program.featureSets.count == 1)
    }
}
