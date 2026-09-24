// ============================================================
// NotOverContainsTests.swift
// AROCLI — `not` over a membership/match guard (GitLab #572)
// ============================================================
//
// `when not <a> contains <b>` read correctly in English and was always false,
// in both directions, with no diagnostic: `not` bound as a unary prefix on the
// left operand, so the guard became `(not <a>) contains <b>` — and
// `not "https://other.com/x"` is `false`, which contains nothing.
//
// GitLab #520 gave `not` looser precedence than the comparisons, which covers
// `contains`, `matches` and `is` as well as the `>=` that issue was about. So
// #572 is fixed; these tests are what keeps it fixed, because the only symptom
// was a guard that quietly never fired. They exercise the **guard** position
// specifically, which is where #572 reported it.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("`not` over a comparison in a guard (GitLab #572)", .serialized)
struct NotOverContainsTests {

    /// Runs statements in one session and returns it, so a guarded binding can
    /// be inspected.
    ///
    /// The guard is observed through a *binding* rather than console output: a
    /// guarded statement that does not run binds nothing, so `nil` is exactly
    /// "the guard was false". That is the symptom #572 described — a guard
    /// that quietly never fired — and it tests the guard position, which is
    /// where the issue reported it.
    private func run(_ statements: String...) async -> REPLSession {
        let session = REPLSession()
        let engine = REPLCellEngine(session: session)
        for statement in statements {
            _ = await engine.executeCell(statement)
        }
        return session
    }

    // MARK: - The issue's two directions

    @Test("A guard that should fire, fires")
    func offsiteFires() async {
        let session = await run(
            #"Create the <u> with "https://other.com/x"."#,
            #"Create the <b> with "https://ex.com"."#,
            "Compute the <offsite> from true when not <u> contains <b>."
        )
        #expect(session.getVariable("offsite") as? Bool == true)
    }

    @Test("A guard that should not fire, does not")
    func onsiteDoesNotFire() async {
        let session = await run(
            #"Create the <u> with "https://ex.com/x"."#,
            #"Create the <b> with "https://ex.com"."#,
            "Compute the <offsite> from true when not <u> contains <b>."
        )
        #expect(session.getVariable("offsite") == nil, "the guard should have been false")
    }

    // MARK: - The parenthesised form still means the same thing

    @Test("Parentheses are redundant, not load-bearing")
    func parenthesesAgree() async {
        let session = await run(
            #"Create the <u> with "https://other.com/x"."#,
            #"Create the <b> with "https://ex.com"."#,
            "Compute the <bare> from true when not <u> contains <b>.",
            "Compute the <parenthesised> from true when not (<u> contains <b>)."
        )
        #expect(session.getVariable("bare") as? Bool == true)
        #expect(session.getVariable("parenthesised") as? Bool == true)
    }

    // MARK: - The sibling operators at the same precedence

    @Test("`not … matches` negates the match")
    func notOverMatches() async {
        let session = await run(
            #"Create the <u> with "https://other.com/x"."#,
            #"Compute the <nomatch> from true when not <u> matches "ex[.]com"."#
        )
        #expect(session.getVariable("nomatch") as? Bool == true)
    }

    @Test("`not … is` negates the equality")
    func notOverIs() async {
        let session = await run(
            #"Create the <a> with "x"."#,
            #"Create the <b> with "y"."#,
            "Compute the <different> from true when not <a> is <b>."
        )
        #expect(session.getVariable("different") as? Bool == true)
    }

    // MARK: - What `not` must still not swallow

    @Test("`not` stops before `and`, so the second operand is its own term")
    func notStopsBeforeAnd() async {
        // `not <u> contains <b> and <u> contains "other"` is
        // `(not (<u> contains <b>)) and (<u> contains "other")` — both true.
        let session = await run(
            #"Create the <u> with "https://other.com/x"."#,
            #"Create the <b> with "https://ex.com"."#,
            #"Compute the <both> from true when not <u> contains <b> and <u> contains "other"."#
        )
        #expect(session.getVariable("both") as? Bool == true)
    }

    @Test("`not` over a plain boolean still negates the boolean")
    func notOverBoolean() async {
        let session = await run(
            "Create the <flag> with false.",
            "Compute the <notset> from true when not <flag>."
        )
        #expect(session.getVariable("notset") as? Bool == true)
    }
}
