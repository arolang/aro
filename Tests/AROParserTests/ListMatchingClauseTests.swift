// ============================================================
// ListMatchingClauseTests.swift
// AROParser — `List … matching "<glob>"` (ARO-0036 §6, GitLab #518)
// ============================================================
//
// ARO-0036 documented `matching "pattern"` and a trailing
// `recursively` on List; neither parsed. `List the <exports> from
// the <directory: out> matching "*.csv".` died on "Expected '.', but
// got identifier(matching)", so the only way to narrow a listing was
// a follow-up `Filter … contains` — substring matching, which keeps
// `report.csvx`.

import Testing
@testable import AROParser

@Suite("List matching clause")
struct ListMatchingClauseTests {

    private func compile(_ statement: String) -> CompilationResult {
        Compiler().compile("""
        (List Probe: Test) {
            Create the <dir> with "./out".
            Create the <glob> with "*.csv".
            \(statement)
            Return an <OK: status> for the <probe>.
        }
        """)
    }

    /// Pulls the List statement out of a compiled probe.
    private func listStatement(_ statement: String) -> AROStatement? {
        let result = compile(statement)
        guard result.isSuccess else { return nil }
        return result.program.featureSets.first?.statements
            .compactMap { $0 as? AROStatement }
            .first { $0.action.verb.lowercased() == "list" }
    }

    @Test("The issue's repro parses")
    func matchingParses() {
        let result = compile(#"List the <exports> from the <directory: dir> matching "*.csv"."#)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }

    @Test("The glob is carried on the statement, not swallowed")
    func matchingIsBound() {
        let statement = listStatement(#"List the <exports> from the <directory: dir> matching "*.csv"."#)
        #expect(statement?.queryModifiers.matchingPattern != nil)
        #expect(statement?.description.contains("matching") == true)
    }

    @Test("A variable works as the glob")
    func matchingFromVariable() {
        let statement = listStatement("List the <exports> from the <directory: dir> matching <glob>.")
        #expect(statement?.queryModifiers.matchingPattern != nil)
    }

    @Test("Trailing `recursively` parses (ARO-0036 §6.3)")
    func recursivelyParses() {
        let statement = listStatement("List the <all> from the <directory: dir> recursively.")
        #expect(statement?.queryModifiers.recursive == true)
    }

    @Test("`matching` and `recursively` combine (ARO-0036 §6.4)")
    func matchingAndRecursively() {
        let statement = listStatement(#"List the <tests> from the <directory: dir> matching "*_test.aro" recursively."#)
        #expect(statement?.queryModifiers.matchingPattern != nil)
        #expect(statement?.queryModifiers.recursive == true)
    }

    @Test("A plain listing carries neither")
    func plainListingUnaffected() {
        let statement = listStatement("List the <entries> from the <directory: dir>.")
        #expect(statement != nil)
        #expect(statement?.queryModifiers.matchingPattern == nil)
        #expect(statement?.queryModifiers.recursive == false)
        #expect(statement?.queryModifiers.isEmpty == true)
    }

    @Test("`matching` with nothing after it names what it wanted")
    func matchingNeedsAPattern() {
        let result = compile("List the <exports> from the <directory: dir> matching.")
        #expect(!result.isSuccess)
        let all = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(all.contains("glob pattern after 'matching'"))
    }

    @Test("`matching` on a verb that ignores it is a check-time error")
    func matchingRejectedOnOtherVerbs() {
        // Silently returning the *unfiltered* value is the failure mode this
        // rejects: the clause binds, the action never reads it.
        let result = compile(#"Retrieve the <exports> from the <dir> matching "*.csv"."#)
        #expect(!result.isSuccess)
        let all = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(all.contains("'matching' is a List clause"))
        #expect(all.contains("Retrieve ignores it"))
    }

    @Test("`recursively` on a verb that ignores it is a check-time error")
    func recursivelyRejectedOnOtherVerbs() {
        let result = compile("Filter the <exports> from the <dir> recursively.")
        #expect(!result.isSuccess)
        let all = result.diagnostics.map(\.message).joined(separator: "\n")
        #expect(all.contains("'recursively' is a List clause"))
    }

    @Test("Neighbouring clauses still parse after the new ones", arguments: [
        #"List the <exports> from the <directory: dir> matching "*.csv" when <dir> is not empty."#,
        "List the <all> from the <directory: dir> recursively when <dir> is not empty.",
    ])
    func clausesCompose(_ statement: String) {
        let result = compile(statement)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }

    @Test("`matching` is not a reserved word")
    func matchingStaysAnIdentifier() {
        // Recognised positionally, like `default` — so a variable may still
        // be called `matching` without the parser reading it as a clause.
        let result = compile("""
        Create the <matching> with "yes".
            Log <matching> to the <console>.
        """)
        #expect(result.isSuccess, "\(result.diagnostics.map(\.message))")
    }
}
