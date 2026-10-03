// ============================================================
// NotebookStreamBudget.swift
// SOLARO — one cell's run may only print so much (GitLab #531)
// ============================================================
//
// `appendStream` accumulated every chunk a cell produced with no cap on
// either the number of outputs or the length of the text, on the MainActor,
// re-rendering an ever-growing `Text` per chunk and re-encoding the whole
// document to JSON every 800 ms. A loop that `Log`s aggressively — the first
// thing a learner writes — froze the UI progressively and left a
// multi-megabyte `.repl` file behind that made every later open slow and
// every diff unreadable.
//
// The console had the same problem and solved it by dropping the oldest half
// (`ConsoleProcess.logCap`). A notebook cell wants the opposite policy: the
// interesting part of a runaway loop is where it started, and the output is
// persisted, so this keeps the **head** and says what it dropped. Jupyter
// does the same thing, down to the wording of the notice.
//
// Kept as a value type rather than inline in the controller so the arithmetic
// is testable without a kernel, a window or an autosave.

import Foundation

/// How much stream output one run of one cell may keep, and what was dropped.
struct NotebookStreamBudget: Equatable, Sendable {

    /// Bytes of stream text kept per cell, per run.
    ///
    /// 1 MB is far past any output a person reads and far short of what makes
    /// the document slow: a `.repl` holding a few of these still opens
    /// instantly, and a `Text` view of it still lays out.
    static let byteCap = 1_000_000

    /// UTF-8 bytes admitted so far.
    private(set) var kept = 0

    /// UTF-8 bytes refused after the cap was reached.
    private(set) var suppressed = 0

    /// Whether anything has been refused — i.e. whether a notice belongs at
    /// the end of this cell's outputs.
    var isTruncated: Bool { suppressed > 0 }

    /// Admit as much of `text` as the budget allows, and account for the rest.
    ///
    /// Returns the portion to append, which is empty once the cap is reached.
    /// A chunk that straddles the cap is cut at the last newline inside the
    /// budget where there is one, so the kept output ends on a whole line
    /// rather than mid-token.
    mutating func admit(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        let room = Self.byteCap - kept
        guard room > 0 else {
            suppressed += text.utf8.count
            return ""
        }
        let size = text.utf8.count
        guard size > room else {
            kept += size
            return text
        }
        let head = Self.head(of: text, withinBytes: room)
        kept += head.utf8.count
        suppressed += size - head.utf8.count
        return head
    }

    /// Start of a fresh run: the previous run's outputs are cleared with it.
    mutating func reset() {
        kept = 0
        suppressed = 0
    }

    /// What the trailing notice should say. Phrased as the issue asked, with
    /// the byte count rendered the way the rest of SOLARO renders sizes.
    var notice: String {
        "… output truncated — \(Self.formatBytes(suppressed)) more suppressed; "
            + "re-run with a lower log volume."
    }

    // MARK: - Helpers

    /// The longest prefix of `text` that fits in `budget` UTF-8 bytes, cut at
    /// a line boundary when one is available in the last quarter of it.
    ///
    /// Character by character rather than `String(decoding: utf8.prefix(…))`,
    /// which can split a scalar and leave a replacement character behind.
    static func head(of text: String, withinBytes budget: Int) -> String {
        var out = ""
        var used = 0
        for character in text {
            let width = String(character).utf8.count
            if used + width > budget { break }
            out.append(character)
            used += width
        }
        // Prefer ending on a whole line, but never throw away most of the
        // chunk to get one: a single enormous line keeps its prefix.
        if let newline = out.lastIndex(of: "\n"),
           out.distance(from: out.startIndex, to: newline) > out.count * 3 / 4 {
            return String(out[out.startIndex...newline])
        }
        return out
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}
