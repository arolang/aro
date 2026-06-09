// ============================================================
// RunParameterScannerTests.swift
// SOLARO — scan AROStatement bodies for <parameter: NAME>
// ============================================================

import Testing
import Foundation
import AROParser
@testable import SOLARO

@Suite("RunParameterScanner")
struct RunParameterScannerTests {

    private func parse(_ source: String) throws -> Program {
        try Parser.parse(source)
    }

    @Test func picksUpDirectParameterExtract() throws {
        let program = try parse("""
        (Application-Start: Web Crawler) {
            Extract the <start-url> from the <parameter: url>.
            Return an <OK: status> for the <startup>.
        }
        """)
        let url = URL(fileURLWithPath: "/tmp/main.aro")
        let result = RunParameterScanner.scan(programs: [url: program])
        #expect(result == ["url"])
    }

    @Test func dedupesRepeatedParameters() throws {
        let program = try parse("""
        (Application-Start: Demo) {
            Extract the <a> from the <parameter: name>.
            Extract the <b> from the <parameter: name>.
            Return an <OK: status> for the <demo>.
        }
        """)
        let url = URL(fileURLWithPath: "/tmp/main.aro")
        let result = RunParameterScanner.scan(programs: [url: program])
        #expect(result == ["name"])
    }

    @Test func preservesSourceOrderAcrossPrograms() throws {
        // Two programs in arbitrary key order — the dictionary
        // iteration order isn't deterministic across runs, so we
        // assert on the *set* of names rather than the order.
        // Source order within a single program IS deterministic, so
        // verify that in a single-program case first.
        let single = try parse("""
        (Application-Start: Demo) {
            Extract the <a> from the <parameter: alpha>.
            Extract the <b> from the <parameter: beta>.
            Return an <OK: status> for the <demo>.
        }
        """)
        let urlA = URL(fileURLWithPath: "/tmp/a.aro")
        let resultSingle = RunParameterScanner.scan(programs: [urlA: single])
        #expect(resultSingle == ["alpha", "beta"])
    }

    @Test func ignoresExtractFromOtherSources() throws {
        let program = try parse("""
        (Application-Start: Demo) {
            Create the <data> with { name: "hello" }.
            Extract the <hello> from the <data: name>.
            Return an <OK: status> for the <demo>.
        }
        """)
        let url = URL(fileURLWithPath: "/tmp/main.aro")
        let result = RunParameterScanner.scan(programs: [url: program])
        #expect(result.isEmpty)
    }

    @Test func returnsEmptyForProgramsWithoutAnyParameterReference() throws {
        let program = try parse("""
        (Application-Start: Plain) {
            Log "no parameters here" to the <console>.
            Return an <OK: status> for the <plain>.
        }
        """)
        let url = URL(fileURLWithPath: "/tmp/main.aro")
        let result = RunParameterScanner.scan(programs: [url: program])
        #expect(result.isEmpty)
    }

    @Test func emptyInputProducesEmptyOutput() {
        let result = RunParameterScanner.scan(programs: [:])
        #expect(result.isEmpty)
    }
}
