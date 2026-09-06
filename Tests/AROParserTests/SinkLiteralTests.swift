// ============================================================
// SinkLiteralTests.swift
// AROParser — bare literals in sink position (GitLab #512)
// ============================================================
//
// ARO-0043 §grammar lists string, number, boolean, object and array
// literals as sink expressions, but `isSinkSyntaxStart` only knew
// string and number tokens — so `Log true to the <console>.` was a
// parse error ("Expected '<', but got true") in the one action every
// beginner meets first. These tests pin the full literal set.

import Testing
@testable import AROParser

@Suite("Sink literals")
struct SinkLiteralTests {

    private func parses(_ source: String) -> Bool {
        let wrapped = """
        (Sink Literal Probe: Test) {
            \(source)
            Return an <OK: status> for the <probe>.
        }
        """
        return Compiler().compile(wrapped).isSuccess
    }

    @Test("Boolean literals parse in Log's result slot", arguments: [
        "Log true to the <console>.",
        "Log false to the <console>.",
    ])
    func booleans(_ statement: String) {
        #expect(parses(statement))
    }

    @Test("nil and null literals parse in Log's result slot", arguments: [
        "Log nil to the <console>.",
        "Log null to the <console>.",
    ])
    func nils(_ statement: String) {
        #expect(parses(statement))
    }

    @Test("The already-working literal kinds keep working", arguments: [
        #"Log "text" to the <console>."#,
        "Log 42 to the <console>.",
        "Log 3.14 to the <console>.",
        "Log [1, 2, 3] to the <console>.",
        #"Log { ok: true } to the <console>."#,
    ])
    func existingKinds(_ statement: String) {
        #expect(parses(statement))
    }

    @Test("Standard result syntax is untouched")
    func standardSyntax() {
        #expect(parses("Log the <message> to the <console>."))
    }

    @Test("Non-sink verbs still require a result descriptor")
    func nonSinkVerbsUnchanged() {
        // Return is not a sink verb; a bare literal there stays an error.
        let result = Compiler().compile("""
        (Non Sink Probe: Test) {
            Return true for the <check>.
        }
        """)
        #expect(!result.isSuccess)
    }
}
