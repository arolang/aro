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

    /// The reported multi-file case: two files, two warnings each. `/fix`
    /// sent the model all four files, it rewrote one, and the sandbox was
    /// built from only what came back — so the other file's warnings were
    /// absent from the count and a rewrite that fixed nothing scored 4 → 2.
    private let twoFiles = """
    crawler.aro:
      38:5: warning: Event 'SavePage' is emitted but no handler exists
        hint: Create a handler with business activity 'SavePage Handler'
      42:5: warning: Event 'ExtractLinks' is emitted but no handler exists
      Found 2 warning(s) in crawler.aro
    main.aro:
      81:13: warning: Variable 'max-iters' is defined but never used
      53:5: warning: Event 'QueueUrl' is emitted but no handler exists
      Found 2 warning(s) in main.aro

    ⚠️  4 warning(s) found
    """

    @Test("Names every file the report has diagnostics for, in report order")
    func listsFilesWithDiagnostics() {
        let outcome = AskSession.CheckOutcome.classify(exitCode: 0, stdout: twoFiles, stderr: "")

        #expect(outcome.filesWithDiagnostics == ["crawler.aro", "main.aro"])
        #expect(outcome.warningCount == 4)
    }

    // The per-file tally is indented and the banner is not a path, so
    // neither may be mistaken for a file header — that would put a
    // non-existent file in front of the model.
    @Test("The per-file tally and summary banner are not mistaken for files")
    func onlyRealFileHeadersCount() {
        let outcome = AskSession.CheckOutcome.classify(exitCode: 0, stdout: twoFiles, stderr: "")

        #expect(outcome.filesWithDiagnostics.count == 2)
        #expect(!outcome.filesWithDiagnostics.contains { $0.contains("Found") })
    }

    @Test("A clean report names no files")
    func cleanReportNamesNoFiles() {
        let outcome = AskSession.CheckOutcome.classify(
            exitCode: 0,
            stdout: "✅ No issues found in 3 file(s)",
            stderr: ""
        )

        #expect(outcome.filesWithDiagnostics.isEmpty)
    }

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

// ============================================================
// Deterministic repairs
// ============================================================
//
// `aro check` reports an unused variable with the line that binds it, so
// removing it needs no model. It used to go through one anyway, and lost:
// a five-line file with a single unused variable survived five attempts
// unfixed. These pin the parsing and the refusal to guess.

@Suite("removingUnusedVariables — repairs that need no model")
struct UnusedVariableRepairTests {

    private let source = """
    (Application-Start: Simple Demo) {
        Log "starting" to the <console>.
        Compute the <max-iters> from 5 * 2.
        Return an <OK: status> for the <startup>.
    }
    """

    private func report(line: Int, name: String, file: String = "main.aro") -> String {
        """
        \(file):
          \(line):5: warning: Variable '\(name)' is defined but never used

        ⚠️  1 warning(s) found
        """
    }

    @Test("Deletes the binding statement and nothing else")
    func deletesTheBindingLine() {
        let fixed = AskSession.removingUnusedVariables(
            from: ["main.aro": source],
            report: report(line: 3, name: "max-iters")
        )

        #expect(fixed["main.aro"]?.contains("max-iters") == false)
        // Every other line survives byte for byte — the whole point of not
        // asking a model to retype the file.
        #expect(fixed["main.aro"]?.contains(#"Log "starting" to the <console>."#) == true)
        #expect(fixed["main.aro"]?.contains("Return an <OK: status> for the <startup>.") == true)
        #expect(fixed["main.aro"]?.components(separatedBy: "\n").count == 4)
    }

    // A line number that does not mention the variable means the report and
    // the file disagree; deleting on that basis would destroy a good line.
    @Test("Refuses to delete a line that does not mention the variable")
    func refusesOnMismatch() {
        let fixed = AskSession.removingUnusedVariables(
            from: ["main.aro": source],
            report: report(line: 2, name: "max-iters")
        )

        #expect(fixed.isEmpty)
    }

    @Test("Leaves files the report never mentions alone")
    func onlyTouchesReportedFiles() {
        let fixed = AskSession.removingUnusedVariables(
            from: ["main.aro": source, "other.aro": source],
            report: report(line: 3, name: "max-iters")
        )

        #expect(fixed.keys.sorted() == ["main.aro"])
    }

    // Deleting top-down would shift every later line by one and take the
    // wrong statement with the second deletion.
    @Test("Multiple deletions in one file do not shift each other")
    func multipleDeletionsStayAligned() {
        let two = """
        (Application-Start: Demo) {
            Compute the <a> from 1.
            Log "keep me" to the <console>.
            Compute the <b> from 2.
            Return an <OK: status> for the <startup>.
        }
        """
        let combined = """
        main.aro:
          2:5: warning: Variable 'a' is defined but never used
          4:5: warning: Variable 'b' is defined but never used

        ⚠️  2 warning(s) found
        """

        let fixed = AskSession.removingUnusedVariables(from: ["main.aro": two], report: combined)

        #expect(fixed["main.aro"]?.contains("<a>") == false)
        #expect(fixed["main.aro"]?.contains("<b>") == false)
        #expect(fixed["main.aro"]?.contains(#"Log "keep me" to the <console>."#) == true)
    }

    @Test("A report with no unused variables proposes nothing")
    func noUnusedVariablesNoChange() {
        let fixed = AskSession.removingUnusedVariables(
            from: ["main.aro": source],
            report: """
            main.aro:
              3:5: warning: Event 'QueueUrl' is emitted but no handler exists
            """
        )

        #expect(fixed.isEmpty)
    }
}

// ============================================================
// Unhandled events
// ============================================================
//
// An unhandled event is fixed by ADDING a feature set, so the model only
// has to write the handler and the append is done in code. Locating them
// is the part that must not guess.

@Suite("unhandledEvents — locating handlers that need writing")
struct UnhandledEventTests {

    /// The Crawler's report: two events in one file, one in another,
    /// alongside an unused variable that this parser must ignore.
    private let report = """
    crawler.aro:
      38:5: warning: Event 'SavePage' is emitted but no handler exists
        hint: Create a handler with business activity 'SavePage Handler'
        hint: Or remove this Emit statement if the event is not needed
      42:5: warning: Event 'ExtractLinks' is emitted but no handler exists
      Found 2 warning(s) in crawler.aro
    main.aro:
      81:13: warning: Variable 'max-iters' is defined but never used
      53:5: warning: Event 'QueueUrl' is emitted but no handler exists
      Found 2 warning(s) in main.aro

    ⚠️  4 warning(s) found
    """

    @Test("Finds every unhandled event with its file and line")
    func findsAllEvents() {
        let events = AskSession.unhandledEvents(in: report)

        #expect(events.count == 3)
        #expect(events.map(\.event) == ["SavePage", "ExtractLinks", "QueueUrl"])
        #expect(events.map(\.file) == ["crawler.aro", "crawler.aro", "main.aro"])
        #expect(events.map(\.line) == [38, 42, 53])
    }

    // The unused-variable warning in the same report belongs to the other
    // repair; picking it up here would ask the model for a handler for a
    // variable.
    @Test("Ignores warnings that are not unhandled events")
    func ignoresOtherWarnings() {
        let events = AskSession.unhandledEvents(in: report)

        #expect(!events.contains { $0.event.contains("max-iters") })
    }

    // The same event emitted twice needs one handler, not two — the second
    // append would silence nothing and add a duplicate feature set.
    @Test("The same event in one file is reported once")
    func deduplicatesPerFile() {
        let twice = """
        crawler.aro:
          10:5: warning: Event 'SavePage' is emitted but no handler exists
          20:5: warning: Event 'SavePage' is emitted but no handler exists
        """

        #expect(AskSession.unhandledEvents(in: twice).count == 1)
    }

    @Test("A clean report needs no handlers")
    func cleanReportHasNone() {
        #expect(AskSession.unhandledEvents(in: "✅ No issues found in 3 file(s)").isEmpty)
    }
}
