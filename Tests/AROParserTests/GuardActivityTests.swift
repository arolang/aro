// ============================================================
// GuardActivityTests.swift
// ARO Parser Tests - "Guard" in a business activity (GitLab #584)
// ============================================================
//
// `(Application-Start: Guard)` failed with "Missing business activity",
// pointing at the activity it had just read. `guard` is a lexer keyword, so
// `isIdentifierLike` was false for it and `parseIdentifierSequence` stopped
// before consuming anything — leaving the activity empty.
//
// The parser never consumes `.guard` as a keyword anywhere: a guard clause is
// written `when` or `where`. So the reserved word existed only to break an
// identifier sequence, and "Guard" is an ordinary domain noun — *Access
// Guard*, *Rate Guard*, *Schema Guard*.

import Testing
@testable import AROParser

@Suite("\"Guard\" in a business activity (GitLab #584)")
struct GuardActivityTests {

    private func errors(_ source: String) -> [Diagnostic] {
        Compiler().compile(source).diagnostics.filter { $0.severity == .error }
    }

    // MARK: - The issue's three spellings

    @Test("A bare `Guard` activity parses")
    func bareGuard() {
        #expect(errors("""
        (Application-Start: Guard) {
            Return an <OK: status> for the <x>.
        }
        """).isEmpty)
    }

    @Test("`Guard` at the end of a phrase parses")
    func trailingGuard() {
        #expect(errors("""
        (Rate Check: Alpha Guard) {
            Return an <OK: status> for the <x>.
        }
        (Application-Start: Main) {
            Return an <OK: status> for the <x>.
        }
        """).isEmpty)
    }

    @Test("`Guard` at the start of a phrase parses")
    func leadingGuard() {
        #expect(errors("""
        (Schema Check: Guard Check) {
            Return an <OK: status> for the <x>.
        }
        (Application-Start: Main) {
            Return an <OK: status> for the <x>.
        }
        """).isEmpty)
    }

    @Test("The activity is the text as written, not a truncation")
    func activityTextSurvives() {
        let program = Compiler().compile("""
        (Application-Start: Access Guard) {
            Return an <OK: status> for the <x>.
        }
        """)
        let activities = program.analyzedProgram.program.featureSets.map(\.businessActivity)
        #expect(activities == ["Access Guard"])
    }

    @Test("A feature set name may contain Guard too")
    func nameMayContainGuard() {
        let program = Compiler().compile("""
        (Rate Guard: Application-Start) {
            Return an <OK: status> for the <x>.
        }
        """)
        let names = program.analyzedProgram.program.featureSets.map(\.name)
        #expect(names == ["Rate Guard"])
    }

    // MARK: - The shapes that already worked stay working

    @Test("The near-misses the issue lists still parse")
    func nearMissesStillParse() {
        for activity in ["Guards", "Check", "Alpha Check"] {
            #expect(errors("""
            (Application-Start: \(activity)) {
                Return an <OK: status> for the <x>.
            }
            """).isEmpty, "\(activity) regressed")
        }
    }

    @Test("A genuinely missing activity is still reported")
    func missingActivityStillReported() {
        // The error has to survive for the case it was written for.
        let diagnostics = errors("""
        (Application-Start: ) {
            Return an <OK: status> for the <x>.
        }
        """)
        #expect(diagnostics.contains { $0.message.contains("Missing business activity") },
                "\(diagnostics)")
    }

    // MARK: - Guard clauses are unaffected

    @Test("A when guard still applies under a Guard activity")
    func whenGuardStillWorks() {
        #expect(errors("""
        (Application-Start: Access Guard) {
            Create the <n> with 5.
            Log "yes" to the <console> when <n> > 1.
            Return an <OK: status> for the <x>.
        }
        """).isEmpty)
    }

    @Test("`guard` is identifier-like, alongside the other activity-safe keywords")
    func tokenIsIdentifierLike() {
        #expect(TokenKind.guard.isIdentifierLike)
        // The precedent it joins.
        #expect(TokenKind.error.isIdentifierLike)
        #expect(TokenKind.match.isIdentifierLike)
        // And a keyword that must not be: `when` starts a guard clause.
        #expect(!TokenKind.when.isIdentifierLike)
    }
}
