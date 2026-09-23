// ============================================================
// BailoutGuard.swift
// AROAsk - the model ended the turn without doing the work
// ============================================================
//
// GitLab #871. `aro ask` already has three corrective retries, and each one
// matches a specific shape somebody observed: a `<think>` block with nothing
// after it, an empty reply, a tool call written inside a ```bash fence.
//
// A shape list only catches the shapes someone thought of. The reference
// implementation makes the point better than a summary can:
//
//   > a phrase list only catches the wordings someone thought of. "Sie
//   > müssten die Zimmerzahlen über die `search_profiles_advanced` Funktion
//   > abfragen" reads like a helpful answer and matches no marker, but it is
//   > the same failure — the model knew which call to make and left it to the
//   > reader, who cannot make it.
//
// So two checks here are *structural*: they do not look for a wording, they
// look at what the turn did.
//
//   1. The answer hands the reader a tool name. `looksLikeDisguisedToolCall`
//      catches the fenced-command version and explicitly lets prose through
//      — "prose that merely names a tool is fine" — but "you can run
//      `aro_check` on that directory" is the same failure in a sentence.
//   2. The turn produced ARO code and never checked it. The prompt says to
//      run `aro_check` after every write; a model that skipped it has handed
//      over code nobody verified, which is the one thing `aro ask` is
//      supposed to be better at than a general assistant.
//
// Each fires once per run. A model that ignores the first nudge will ignore
// the second, and each nudge costs the reader a full regeneration of an
// answer they already watched arrive.

import Foundation

/// Detects a turn that ended without doing the work, and says what to do.
struct BailoutGuard: Sendable {

    /// What the guard found.
    enum Finding: Sendable, Equatable, Hashable {
        /// The answer told the reader to run a tool.
        case handedOverAToolName(String)
        /// The answer contains ARO and the run never checked it.
        case wroteCodeWithoutChecking

        /// The correction to send, phrased as the thing to do rather than
        /// the thing not to have done.
        var nudge: String {
            switch self {
            case .handedOverAToolName(let name):
                return """
                You named the `\(name)` tool in your answer instead of calling it. \
                The reader cannot run it — only you can. Invoke `\(name)` through \
                the tool-call protocol now, then answer from what it returns.
                """
            case .wroteCodeWithoutChecking:
                return """
                You wrote ARO code and did not check it. Run `aro_check` on the \
                file or directory you touched, fix anything it reports, and only \
                then give your answer.
                """
            }
        }
    }

    /// Verbs that turn a mention of a tool into an instruction to the reader.
    ///
    /// A sentence explaining what a tool *is* ("read_file returns numbered
    /// lines") is documentation and fine. A sentence telling somebody to run
    /// one is the failure, and these are how English says it.
    private static let handOverPhrases = [
        "you can run", "you could run", "you can use", "you could use",
        "you should run", "you need to run", "you'll need to run",
        "you will need to run", "run the", "use the", "try running",
        "call the", "invoke the", "please run",
    ]

    /// Fenced ARO code in an answer.
    static func containsAROCode(_ text: String) -> Bool {
        text.contains("```aro")
    }

    /// Whether the answer hands the reader a tool name to run.
    ///
    /// Requires both a tool name and a phrase that makes it an instruction,
    /// because `aro ask` is asked about its own tools often enough that the
    /// name alone cannot be the signal.
    static func handedOverToolName(in text: String, toolNames: [String]) -> String? {
        let lower = text.lowercased()
        guard handOverPhrases.contains(where: lower.contains) else { return nil }
        // Longest first: `aro_check` must not match inside a hypothetical
        // `aro_check_all` and report the shorter name.
        for name in toolNames.sorted(by: { $0.count > $1.count }) where lower.contains(name.lowercased()) {
            return name
        }
        return nil
    }

    /// What, if anything, this turn failed to do.
    ///
    /// - Parameters:
    ///   - answer: the assistant's text, thinking already stripped.
    ///   - toolNames: the tools attached to this run.
    ///   - toolCallsMade: names of every tool call dispatched in this run.
    ///   - alreadyFired: findings already nudged about, so each fires once.
    static func inspect(
        answer: String,
        toolNames: [String],
        toolCallsMade: [String],
        alreadyFired: Set<Finding>
    ) -> Finding? {
        // A turn that acted and also mentioned a tool is not handing work
        // over — it is explaining what it did.
        if toolCallsMade.isEmpty,
           let name = handedOverToolName(in: answer, toolNames: toolNames) {
            let finding = Finding.handedOverAToolName(name)
            if !alreadyFired.contains(finding) { return finding }
        }

        if containsAROCode(answer),
           toolNames.contains("aro_check"),
           !toolCallsMade.contains("aro_check") {
            let finding = Finding.wroteCodeWithoutChecking
            if !alreadyFired.contains(finding) { return finding }
        }

        return nil
    }
}
