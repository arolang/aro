// ============================================================
// HeaderKeywordTests.swift
// AROParser — a business activity is prose, not a keyword-free zone
// GitLab #855
// ============================================================
//
// `(Application-Start: Env Require)` failed to parse:
//
//     1:25: error: Expected ')', but got the keyword 'Require'
//     error: No Application-Start feature set — the application has no entry point
//
// The second line is the one that makes this worth a suite of its own. Because
// the header failed, the file contributed no feature sets, so the author was
// told their application has no entry point when it plainly does — and the
// real cause is four words earlier on the line above.
//
// The header between `(` and `)` is a name and a business activity. Both are
// the author naming their own domain, and the language has no reason to
// reserve *Order Each Item*, *Parallel Work Queue* or *Break Room Booking*.

import Foundation
import Testing
@testable import AROParser

@Suite("Keywords in a feature set header (#855)")
struct HeaderKeywordTests {

    private func compile(_ source: String) -> CompilationResult {
        Compiler().compile(source)
    }

    private func errors(_ result: CompilationResult) -> [String] {
        result.diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    private func featureSet(activity: String) -> String {
        """
        (Application-Start: \(activity)) {
            Log "x" to the <console>.
            Return an <OK: status> for the <d>.
        }
        """
    }

    /// Every statement keyword named in the issue, plus the one from #584 that
    /// was fixed by hand and is the reason this is a rule rather than a list.
    static let activities = [
        "Env Require", "Order Each", "Parallel Work", "Break Room",
        "Access Guard", "Match Making", "Case Management", "Else Where",
        "Return Policy", "Store Front", "Stream Team", "While Loop Demo"
    ]

    @Test("A business activity containing a statement keyword parses", arguments: activities)
    func activityWithKeywordParses(_ activity: String) {
        let result = compile(featureSet(activity: activity))
        #expect(errors(result).isEmpty, "\(activity): \(errors(result))")
    }

    @Test("The activity survives intact, because event routing matches on it", arguments: activities)
    func activityRoundTrips(_ activity: String) {
        // Routing is string matching — `{Name} Handler`, `{repo} Observer` —
        // so an activity that parses but arrives mangled is a subtler version
        // of the same bug.
        let result = compile(featureSet(activity: activity))
        #expect(result.program.featureSets.first?.businessActivity == activity)
    }

    @Test("A keyword in the feature set *name* parses too")
    func nameWithKeywordParses() {
        // The name is free text for the same reason the activity is, and it is
        // what `Application.<Name>` and the event log show.
        let result = compile("""
            (Break Room Booking: OrderPlaced Handler) {
                Return an <OK: status> for the <e>.
            }
            """)
        #expect(errors(result).isEmpty, "\(errors(result))")
        #expect(result.program.featureSets.first?.name == "Break Room Booking")
    }

    @Test("An entry point with a keyword activity is still found")
    func entryPointIsStillDiscovered() {
        // The misleading half of the original report: a header that fails to
        // parse takes the whole feature set with it, so the *next* error is
        // "no entry point" about an application that has one.
        let result = compile(featureSet(activity: "Env Require"))
        #expect(result.program.featureSets.contains { $0.name == "Application-Start" } == true)
    }

    // MARK: - Still an error when it should be

    @Test("A header with no colon is still an error")
    func missingColonStillFails() {
        let result = compile("(Foo Bar) { Return an <OK: status> for the <d>. }")
        #expect(errors(result).contains { $0.contains("Expected ':'") })
    }

    @Test("A header with no activity is still an error")
    func missingActivityStillFails() {
        let result = compile("(Foo: ) { Return an <OK: status> for the <d>. }")
        #expect(errors(result).contains { $0.contains("Missing business activity") })
    }

    @Test("A header with no name is still an error")
    func missingNameStillFails() {
        let result = compile("( : Activity) { Return an <OK: status> for the <d>. }")
        #expect(errors(result).contains { $0.contains("Missing feature set name") })
    }

    @Test("A literal is not a word, so it cannot pad a header")
    func literalsAreNotWords() {
        // `isWordShaped` excludes literals explicitly. A number or string in
        // the header is a mistake and should still say so rather than being
        // absorbed into the name.
        let result = compile("""
            (Application-Start: Demo 42) {
                Return an <OK: status> for the <d>.
            }
            """)
        #expect(!errors(result).isEmpty)
    }

    // MARK: - The takes clause still decomposes

    @Test("`Action takes <field>` still splits into activity and field")
    func userActionHeaderStillWorks() {
        // ARO-0081's header is parsed out of this same sequence, so widening
        // what counts as a word must not disturb it.
        let result = compile("""
            (DoubleValue: Action takes <number>) {
                Return an <OK: status> with { doubled: 2 }.
            }
            """)
        #expect(errors(result).isEmpty, "\(errors(result))")
        let fs = result.program.featureSets.first
        #expect(fs?.businessActivity == "Action")
        #expect(fs?.userActionTakesField == "number")
    }
}
