// ============================================================
// CheckOutcomeTests.swift
// AROAsk - Tests for how /fix reads an `aro check` run
// ============================================================
//
// `/fix` used to decide there was nothing to do from the exit code alone.
// `aro check` exits 0 when it printed only warnings, so a directory that
// `aro check .` reported four warnings for was answered with "aro check
// passed — no errors to fix" by `/fix .` in that same directory. These
// cover the classification that replaced the exit-code test.

import Testing
import Foundation
@testable import AROAsk

@Suite("CheckOutcome — what /fix sees in an aro check run")
struct CheckOutcomeTests {

    /// Verbatim from `aro check` on an app whose only faults are warnings —
    /// the reported case: an unused variable and an unhandled event.
    private let warningsOnly = """
    main.aro:
      2:5: warning: Variable 'max-iters' is defined but never used
      3:5: warning: Event 'QueueUrl' is emitted but no handler exists
        hint: Create a handler with business activity 'QueueUrl Handler'
        hint: Or remove this Emit statement if the event is not needed
      Found 2 warning(s) in main.aro

    ⚠️  2 warning(s) found
    """

    @Test("Warnings with a zero exit are not 'clean'")
    func warningsAreNotClean() {
        let outcome = AskSession.CheckOutcome.classify(exitCode: 0, stdout: warningsOnly, stderr: "")

        #expect(!outcome.isClean)
        #expect(!outcome.hasErrors)
        #expect(outcome.warningCount == 2)
    }

    // `hint:` lines and the "Found N warning(s)" tally carry no
    // `: warning:` marker, so they must not inflate the count — the
    // sample above has five lines mentioning a warning but only two
    // warnings.
    @Test("Hints and the summary banner are not counted as warnings")
    func hintsDoNotInflateTheCount() {
        let outcome = AskSession.CheckOutcome.classify(exitCode: 0, stdout: warningsOnly, stderr: "")

        #expect(outcome.warningCount == 2)
    }

    @Test("A genuinely clean run is clean")
    func cleanRunIsClean() {
        let outcome = AskSession.CheckOutcome.classify(
            exitCode: 0,
            stdout: "✅ No issues found in 3 file(s)",
            stderr: ""
        )

        #expect(outcome.isClean)
        #expect(outcome.warningCount == 0)
        #expect(outcome.summary == "no issues")
    }

    @Test("A non-zero exit is an error, warnings alongside it still counted")
    func errorsComeFromTheExitCode() {
        let outcome = AskSession.CheckOutcome.classify(
            exitCode: 1,
            stdout: """
            main.aro:
              4:1: error: Unexpected token
              7:3: warning: Variable 'x' is defined but never used

            ❌ 1 error(s) found
            ⚠️  1 warning(s) found
            """,
            stderr: ""
        )

        #expect(outcome.hasErrors)
        #expect(outcome.warningCount == 1)
        #expect(!outcome.isClean)
    }

    // Diagnostics go to stdout, but a crash or a usage error lands on
    // stderr. Reading only one stream would throw away whichever carried
    // the failure, so the report keeps both.
    @Test("The report keeps both streams")
    func reportCombinesBothStreams() {
        let outcome = AskSession.CheckOutcome.classify(
            exitCode: 1,
            stdout: "main.aro:",
            stderr: "fatal: could not read openapi.yaml"
        )

        #expect(outcome.report.contains("main.aro:"))
        #expect(outcome.report.contains("could not read openapi.yaml"))
    }

    @Test("Summary names warnings even when no error is involved")
    func summaryNamesWarnings() {
        let outcome = AskSession.CheckOutcome.classify(exitCode: 0, stdout: warningsOnly, stderr: "")

        #expect(outcome.summary == "2 warning(s)")
    }
}
