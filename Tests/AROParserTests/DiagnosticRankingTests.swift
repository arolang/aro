// ============================================================
// DiagnosticRankingTests.swift
// AROParser — root-cause diagnostics headline (GitLab #509)
// ============================================================
//
// A statement with an invented Compute qualifier used to report as
// its FIRST diagnostic "Variable 'x' is defined but never used" or
// "Feature set '…' has no Return or Throw statement" — hygiene
// fallout of the failed statement — while the actual error
// ("Unknown Compute qualifier 'sparkle'", with its did-you-mean)
// sat lower in the list. Front-ends that show only the first line
// (Jupyter evalue, notebook cells) surfaced the noise.
//
// The fix: `CompilationResult.diagnostics` is ranked — errors before
// warnings before notes, root causes before consequential findings,
// emission order preserved within each class. Nothing is dropped or
// reworded; only the order changes.

import Testing
@testable import AROParser

@Suite("Diagnostic ranking (#509)")
struct DiagnosticRankingTests {

    // MARK: - End to end through the compiler

    @Test("Unknown qualifier headlines over unused-variable and missing-return")
    func unknownQualifierHeadlines() {
        let source = """
        (Check: Demo) {
            Create the <y> with "text".
            Compute the <x: sparkle> from <y>.
        }
        """
        let result = Compiler.compile(source)
        #expect(result.hasErrors)

        let first = result.diagnostics.first
        #expect(first?.severity == .error)
        #expect(first?.message.contains("Unknown Compute qualifier 'sparkle'") == true)

        // The consequential warnings are ranked lower, not dropped.
        let messages = result.diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("has no Return or Throw") })
        #expect(messages.contains { $0.contains("is defined but never used") })
    }

    @Test("Missing-return and unused-variable never precede an error")
    func consequentialNeverOutranksError() {
        let source = """
        (Check: Demo) {
            Create the <y> with "text".
            Compute the <x: sparkle> from <y>.
        }
        """
        let result = Compiler.compile(source)
        guard let firstError = result.diagnostics.firstIndex(where: { $0.severity == .error }) else {
            Issue.record("expected an error diagnostic")
            return
        }
        for diagnostic in result.diagnostics.prefix(firstError) {
            #expect(!diagnostic.message.contains("has no Return or Throw"))
            #expect(!diagnostic.message.contains("is defined but never used"))
        }
    }

    @Test("A clean warning-only compile keeps its warnings")
    func warningsSurviveRanking() {
        // No error at all: the missing-return warning is still reported —
        // ranking must not filter, only order.
        let source = """
        (Check: Demo) {
            Log "hello" to the <console>.
        }
        """
        let result = Compiler.compile(source)
        #expect(result.isSuccess)
        #expect(result.diagnostics.contains { $0.message.contains("has no Return or Throw") })
    }

    // MARK: - ranked() as a pure function

    @Test("Errors sort before warnings, notes last")
    func severityOrder() {
        let ranked = [
            Diagnostic(severity: .note, message: "n"),
            Diagnostic(severity: .warning, message: "w"),
            Diagnostic(severity: .error, message: "e"),
        ].ranked()
        #expect(ranked.map(\.message) == ["e", "w", "n"])
    }

    @Test("Within a severity, root causes sort before consequential")
    func categoryOrder() {
        let ranked = [
            Diagnostic(severity: .warning, message: "fallout", category: .consequential),
            Diagnostic(severity: .warning, message: "real", category: .rootCause),
        ].ranked()
        #expect(ranked.map(\.message) == ["real", "fallout"])
    }

    // ========================================================
    // Deterministic order (GitLab #892)
    // ========================================================
    //
    // Ranking by emission index was stable but not deterministic: it kept
    // whatever order the producer emitted, and a producer walking a
    // `Dictionary` has no order to keep. Swift seeds its hasher per process,
    // so `aro check` printed one file's warnings in a different order on every
    // run of an unmodified binary — which makes the output useless as a diff
    // target or a CI baseline.

    @Test("Within one class, located diagnostics sort by position")
    func locatedSortByPosition() {
        func at(_ line: Int, _ column: Int, _ message: String) -> Diagnostic {
            Diagnostic(severity: .warning, message: message,
                       location: SourceLocation(line: line, column: column, offset: 0))
        }
        // Emitted out of order, as a dictionary walk would.
        let ranked = [at(28, 5, "b"), at(3, 1, "a"), at(28, 2, "c")].ranked()
        #expect(ranked.map(\.message) == ["a", "c", "b"],
                "column breaks a tie on line")
    }

    @Test("Emission order no longer decides a located pair")
    func emissionOrderDoesNotDecide() {
        // The property #892 needs: two orderings of the same findings rank
        // identically. A producer whose iteration order varies per process
        // cannot change the output any more.
        func at(_ line: Int, _ message: String) -> Diagnostic {
            Diagnostic(severity: .warning, message: message,
                       location: SourceLocation(line: line, column: 5, offset: 0))
        }
        let forwards = [at(27, "text"), at(28, "name"), at(35, "qty")].ranked()
        let backwards = [at(35, "qty"), at(28, "name"), at(27, "text")].ranked()
        #expect(forwards.map(\.message) == backwards.map(\.message))
        #expect(forwards.map(\.message) == ["text", "name", "qty"])
    }

    @Test("A diagnostic with no location sorts after the located ones")
    func unlocatedSortsLast() {
        // "No Application-Start" is about the file, not a line in it, and
        // belongs under the lines rather than ahead of line 1.
        let ranked = [
            Diagnostic(severity: .error, message: "whole file"),
            Diagnostic(severity: .error, message: "line 9",
                       location: SourceLocation(line: 9, column: 1, offset: 0)),
        ].ranked()
        #expect(ranked.map(\.message) == ["line 9", "whole file"])
    }

    @Test("Severity and category still outrank position")
    func classStillOutranksPosition() {
        // Position orders *within* a class; it must not promote a late-line
        // warning above an early-line error (#509's guarantee).
        let ranked = [
            Diagnostic(severity: .warning, message: "early warning",
                       location: SourceLocation(line: 1, column: 1, offset: 0)),
            Diagnostic(severity: .error, message: "late error",
                       location: SourceLocation(line: 99, column: 1, offset: 0)),
        ].ranked()
        #expect(ranked.map(\.message) == ["late error", "early warning"])
    }

    @Test("Within one class, emission order is preserved")
    func stableWithinClass() {
        let ranked = [
            Diagnostic(severity: .error, message: "first error"),
            Diagnostic(severity: .warning, message: "first warning"),
            Diagnostic(severity: .error, message: "second error"),
            Diagnostic(severity: .warning, message: "second warning"),
        ].ranked()
        #expect(ranked.map(\.message) == [
            "first error", "second error", "first warning", "second warning",
        ])
    }
}
