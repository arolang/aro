// ============================================================
// CanvasAccessibility.swift
// SOLARO — what the canvas says out loud (#770)
// ============================================================
//
// Two `accessibilityLabel` calls in fifty-odd thousand lines: one on the
// runtime status pill, one on a breakpoint glyph. Canvas nodes, wires,
// repository cards, toolbar controls and notebook cells carried nothing
// — no label, no trait, no value. The canvas *is* the product, so a
// screen-reader user had a text editor and nothing else. It is also a
// procurement blocker for institutional buyers.
//
// The sentences live here rather than inline in the views, for the same
// reason the layout rules do: a label is a piece of writing, it is read
// aloud in order, and it is worth being able to check it as text.
//
// The shape is deliberate. A node reads as what the statement does,
// then where it is, then what is true of it right now — summary, line,
// state — because a screen-reader user scanning a canvas is asking
// "what is this" far more often than "has it run". Live values go in
// `accessibilityValue` instead of the label, so the rotor reads them
// only when asked.

import Foundation

enum CanvasAccessibility {

    // MARK: - Nodes

    /// What one canvas node is.
    ///
    /// `summary` already reads as a sentence — it is the statement's
    /// own source text — so it goes first and unaltered rather than
    /// being paraphrased into something less precise.
    static func nodeLabel(summary: String, line: Int,
                          isPaused: Bool, hasBreakpoint: Bool,
                          hasExecuted: Bool, errorMessage: String?) -> String {
        var parts: [String] = [summary.trimmingCharacters(in: .whitespaces)]
        parts.append("line \(line)")
        if let errorMessage, !errorMessage.isEmpty {
            // The most important thing about a failed statement is that
            // it failed, and what it said.
            parts.append("failed: \(errorMessage)")
        } else if isPaused {
            parts.append("paused here")
        } else if hasExecuted {
            parts.append("executed")
        }
        if hasBreakpoint { parts.append("breakpoint set") }
        return parts.joined(separator: ", ")
    }

    /// The live bindings a node produced, as `accessibilityValue`.
    ///
    /// Separate from the label so a reader moving through the canvas
    /// hears what each statement *is*, and hears values only when they
    /// ask for them.
    static func nodeValue(symbols: [(name: String, value: String)]) -> String? {
        guard !symbols.isEmpty else { return nil }
        return symbols
            .map { "\($0.name) is \($0.value)" }
            .joined(separator: ", ")
    }

    /// A node's hint — what happens if you act on it.
    static let nodeHint = "Double-tap to open this statement in the editor"

    // MARK: - Wires

    /// A data-flow wire between two statements.
    ///
    /// Wires are drawn in one `Canvas`, so they cannot each be an
    /// element; this is the summary the whole layer carries, which is
    /// still better than the silence it carried before.
    static func wiresLabel(count: Int) -> String {
        count == 1
            ? "1 data-flow connection between statements"
            : "\(count) data-flow connections between statements"
    }

    // MARK: - Feature-set containers

    static func featureSetLabel(name: String, activity: String,
                                statementCount: Int) -> String {
        let statements = statementCount == 1
            ? "1 statement" : "\(statementCount) statements"
        return "\(name), \(activity), \(statements)"
    }

    // MARK: - Repositories

    static func repositoryLabel(name: String, rowCount: Int?) -> String {
        guard let rowCount else { return "\(name) repository" }
        let rows = rowCount == 1 ? "1 record" : "\(rowCount) records"
        return "\(name) repository, \(rows)"
    }

    // MARK: - Run state

    /// The toolbar's runtime pill, which had the app's only other
    /// label and said only "Runtime status".
    static func runStateLabel(_ description: String) -> String {
        "Runtime: \(description)"
    }
}
