// ============================================================
// TestResultParserTests.swift
// SOLARO — `aro test` stdout matcher (Swift Testing)
// ============================================================

import Testing
@testable import SOLARO

@Suite("TestResultParser")
struct TestResultParserTests {

    @Test func recognisesPlainPassLines() {
        let hit = TestResultParser.match("  PASS  length-of-hello (5ms)")
        #expect(hit?.name == "length-of-hello")
        #expect(hit?.result == .passed)
    }

    @Test func recognisesPlainFailLines() {
        let hit = TestResultParser.match("  FAIL  length-of-blank (1ms)")
        #expect(hit?.name == "length-of-blank")
        if case .failed = hit?.result {
            // OK
        } else {
            Issue.record("expected .failed result, got \(String(describing: hit?.result))")
        }
    }

    @Test func recognisesErrorLines() {
        let hit = TestResultParser.match("  ERROR  bad-input")
        #expect(hit?.name == "bad-input")
        if case .failed = hit?.result {
            // OK
        } else {
            Issue.record("expected .failed result, got \(String(describing: hit?.result))")
        }
    }

    @Test func stripsANSIColorEscapes() {
        let raw = "  \u{001B}[32mPASS\u{001B}[0m  length-of-hello\u{001B}[90m (5ms)\u{001B}[0m"
        let hit = TestResultParser.match(raw)
        #expect(hit?.name == "length-of-hello")
        #expect(hit?.result == .passed)
    }

    @Test func returnsNilForUnrelatedLines() {
        #expect(TestResultParser.match("Total:  6") == nil)
        #expect(TestResultParser.match("=== ARO Test Results ===") == nil)
        #expect(TestResultParser.match("") == nil)
        #expect(TestResultParser.match("All tests passed!") == nil)
    }

    @Test func dropsDurationSuffix() {
        // Lines with and without `(<duration>)` both come back with
        // the same name — the suffix isn't part of the FS identifier.
        let withDuration = TestResultParser.match("PASS  uppercase-simple (<1ms)")
        let withoutDuration = TestResultParser.match("PASS  uppercase-simple")
        #expect(withDuration?.name == withoutDuration?.name)
        #expect(withDuration?.name == "uppercase-simple")
    }
}
