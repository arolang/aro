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
