// ============================================================
// HelpTextParsesTests.swift
// AROCLI — `:help`'s examples must parse (GitLab #574)
// ============================================================
//
// `HelpCommand`'s text showed every example with the verb in angle brackets:
//
//     Example: <Set> the <x> to 42.
//         <Compute> the <sum> from <a> + <b>.
//         <Return> an <OK: status> with <sum>.
//
// That spelling was removed (GitLab #514). Typing the help text's own example
// into the prompt it is printed at failed with "Expected action verb …, but
// got <". `:help` is what the banner points a new user at, so it was the worst
// possible place for a dead spelling.
//
// This test does not check the wording — it extracts the ARO statements from
// the live help text and parses them, so the text cannot drift out of the
// language again.

import Testing
import Foundation
import AROParser
@testable import AROCLI

@Suite("`:help` teaches what parses (GitLab #574)")
struct HelpTextParsesTests {

    /// The help text as a user sees it. `HelpCommand.help` is the one-line
    /// description; the long text is built inside `execute`, so this runs the
    /// command — which is also what makes the test faithful.
    private func helpText() async throws -> String {
        let result = try await HelpCommand().execute(
            args: [], session: REPLSession(suppressLogPrefix: true))
        guard case .output(let text) = result else {
            throw HelpTextError.notOutput(String(describing: result))
        }
        return text
    }

    private enum HelpTextError: Error { case notOutput(String) }

    /// Statement-shaped lines from the help text: anything ending in `.` that
    /// is not prose. `Example:` prefixes are stripped.
    private func statements(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if let colon = line.range(of: "Example: ") {
                line = String(line[colon.upperBound...])
            }
            guard line.hasSuffix(".") else { return nil }
            // A statement mentions at least one <binding>; prose does not.
            guard line.contains("<") else { return nil }
            return line
        }
    }

    @Test("No example in the help text uses the bracketed-verb spelling")
    func noBracketedVerbs() async throws {
        // The specific regression: a leading `<Verb>`.
        let offenders = statements(in: try await helpText()).filter { $0.hasPrefix("<") }
        #expect(offenders.isEmpty, "bracketed verbs in :help: \(offenders)")
    }

    @Test("Every statement the help text prints actually parses")
    func everyStatementParses() async throws {
        let found = statements(in: try await helpText())
        #expect(!found.isEmpty, "the extraction found nothing — the test is vacuous")

        var failures: [String] = []
        for statement in found {
            let result = Compiler().compile("""
            (Probe: Help) {
                \(statement)
                Return an <OK: status> for the <probe>.
            }
            """)
            let errors = result.diagnostics.filter { $0.severity == .error }
            if !errors.isEmpty {
                failures.append("\(statement) → \(errors.map(\.message).joined(separator: "; "))")
            }
        }
        let detail = failures.joined(separator: "\n")
        #expect(failures.isEmpty, "help text shows statements that do not parse:\n\(detail)")
    }

    @Test("The feature-set example in the help text parses as a whole")
    func featureSetExampleParses() async throws {
        // Reproduced from the text rather than extracted, because the block
        // spans lines; if the text changes shape this needs revisiting, which
        // is the point.
        let errors = Compiler().compile("""
        (Calculate Sum: Math) {
            Compute the <sum> from <a> + <b>.
            Return an <OK: status> with <sum>.
        }
        """).diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors)")

        // And the text really does contain it, bare-verbed.
        let text = try await helpText()
        #expect(text.contains("Compute the <sum> from <a> + <b>."))
        #expect(text.contains("Return an <OK: status> with <sum>."))
        #expect(text.contains("Example: Set the <x> to 42."))
    }
}
