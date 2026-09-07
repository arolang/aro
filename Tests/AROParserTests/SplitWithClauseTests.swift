// ============================================================
// SplitWithClauseTests.swift
// AROParser — Split's delimiter goes after `by` (GitLab #513)
// ============================================================
//
// `Split the <parts> from <csv-line> with ",".` used to parse, run,
// and fail at runtime with "Cannot split …" — `with` is the payload
// preposition everywhere else, so it is the first thing people try.
// Now the mistake is a check-time error whose hint names `by`.

import Testing
@testable import AROParser

@Suite("Split with-clause rejection")
struct SplitWithClauseTests {

    private func compile(_ statement: String) -> CompilationResult {
        Compiler().compile("""
        (Split Probe: Test) {
            Create the <csv-line> with "a,b,c".
            \(statement)
            Return an <OK: status> for the <probe>.
        }
        """)
    }

    @Test("The issue's repro is a check-time error naming 'by'")
    func withDelimiterRejected() {
        let result = compile(#"Split the <parts> from <csv-line> with ","."#)
        #expect(!result.isSuccess)
        let all = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(all.contains("after 'by', not 'with'"))
    }

    @Test("The working spellings stay accepted", arguments: [
        #"Split the <parts> from <csv-line> by ","."#,
        #"Split the <parts> from <csv-line> by /,\s*/."#,
        "Split the <parts> from <csv-line> by <delimiter>.",
    ])
    func bySpellings(_ statement: String) {
        // `by <delimiter>` resolves at runtime; parse+check must be
        // clean — a stray parse error would hide a vacuous pass.
        let result = compile(statement)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }

    @Test("Other verbs keep their with clauses")
    func otherVerbsUnaffected() {
        let result = compile("Compute the <replaced: replace> from <csv-line> with { find: \",\", replace: \";\" }.")
        #expect(result.isSuccess)
    }
}
