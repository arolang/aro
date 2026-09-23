// ============================================================
// RetrievalMemory.swift
// AROAsk - what this run has already been given
// ============================================================
//
// GitLab #874. `grep`, `search_project` and `read_file` each answer
// independently, and nothing tracks what a run has already handed to the
// model. Two searches on related phrasings return overlapping files, and the
// second one spends context re-delivering the first one's results.
//
// The reference implementation measured the cost of exactly this:
//
//   > a run spent twenty item slots on fourteen distinct pages […] Three
//   > arrivals read as three findings, so the answer cited one page three
//   > times instead of the three pages the run had actually found — and the
//   > duplicate slots had already spent the window that other pages needed.
//
// Two costs in one. The window is spent on repeats, *and* repetition reads to
// the model as corroboration: a file that arrives three times looks like
// three independent confirmations of whatever it says.
//
// So a search asks for more than it returns, drops what this run has already
// delivered, and fills the gap from the next-best hits. The model gets n
// *new* results rather than n results it has mostly seen.
//
// One instance per run, shared by the tools attached to it. Without one — a
// tool built outside a run, or a test — every search behaves exactly as it
// did before.

import Foundation

/// The sources one run has already delivered.
public actor RetrievalMemory {

    /// Normalised paths already handed to the model.
    private var delivered: Set<String> = []

    public init() {}

    /// Whether anything has been delivered yet.
    ///
    /// A first search has nothing to exclude, so it does not pay for the
    /// wider fetch.
    public var isEmpty: Bool { delivered.isEmpty }

    /// How many distinct sources this run has seen.
    public var count: Int { delivered.count }

    /// Paths are compared after standardising, so `./x.aro`, `x.aro` and a
    /// path with a redundant `..` in it are one file rather than three.
    static func normalise(_ source: String) -> String {
        URL(fileURLWithPath: source).standardizedFileURL.path
    }

    /// Whether this run has already been given `source`.
    public func hasDelivered(_ source: String) -> Bool {
        delivered.contains(Self.normalise(source))
    }

    /// Record what a search returned.
    public func record(_ sources: [String]) {
        for source in sources { delivered.insert(Self.normalise(source)) }
    }

    /// Keep the first `limit` items this run has not seen, and record them.
    ///
    /// The over-fetch is the caller's business: a search that wants ten new
    /// results should ask its index for more than ten and hand them all
    /// here. This drops the seen ones and takes what is left.
    public func selectUnseen(
        from items: [ToolResultItem],
        limit: Int
    ) -> (kept: [ToolResultItem], skipped: Int) {
        var kept: [ToolResultItem] = []
        var skipped = 0
        for item in items {
            if kept.count >= limit { break }
            if hasDelivered(item.source) { skipped += 1; continue }
            kept.append(item)
        }
        record(kept.map(\.source))
        return (kept, skipped)
    }

    /// The line a search adds when it withheld repeats.
    ///
    /// Said rather than left silent: a result set that is quietly shorter
    /// than asked for reads as "there is nothing more", which is a different
    /// and false claim.
    public static func skippedNotice(_ skipped: Int) -> String? {
        guard skipped > 0 else { return nil }
        return "(\(skipped) result\(skipped == 1 ? "" : "s") omitted — "
             + "already returned to you earlier in this session)"
    }
}
