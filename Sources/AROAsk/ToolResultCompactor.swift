// ============================================================
// ToolResultCompactor.swift
// AROAsk - shrink what has been read, keep where it came from
// ============================================================
//
// GitLab #868. The only answer `aro ask` had to context pressure was
// `compactIfNeeded`: ask the model to summarise older turns. That costs a
// full generation, is lossy in a way nobody can audit, and throws away
// exactly the thing a later turn needs — which file a fact came from, and
// what its path was.
//
// Tool results are where the weight is. A run that reads three files in the
// first four rounds is carrying all three verbatim at round twenty, long
// after the model has taken what it needed from them. So the bodies go and
// the provenance stays, in three ordered steps:
//
//   shortBodies → the first 600 characters of each, which is where a
//                 signature, a feature-set header or a declaration sits
//   noBodies    → paths only, with a marker saying the content was here
//   dropped     → the tool message replaced by a line naming what it read
//
// What never goes is the path. A model that wrote `edit_file` against
// `Sources/Foo.swift` in round eight must still be able to name it in round
// twenty, and a citation has to keep resolving. The marker matters for the
// same reason an empty body would not: "(contents elided)" reads as "this
// was read and is no longer quoted"; an empty string reads as "this file is
// empty", which is a different and false claim.

import Foundation

/// Shrinks tool results in a conversation, preserving provenance.
public enum ToolResultCompactor {

    /// A body cut to this many characters still carries the opening of a
    /// file, which is where the imports, the type name or the feature-set
    /// header are — the part a later turn is most likely to want again.
    public static let shortBodyLimit = 600

    /// How far a result has been shrunk, in the order the steps apply.
    public enum Level: Int, CaseIterable, Sendable, Comparable {
        case shortBodies = 1
        case noBodies = 2
        case dropped = 3

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    /// Left where a body was. Said in words, because an empty result is a
    /// claim about the file rather than about the transcript.
    static func marker(for sources: [String], level: Level) -> String {
        let named = sources.isEmpty ? "earlier output" : sources.joined(separator: ", ")
        switch level {
        case .shortBodies:
            return "… (truncated — re-read \(named) if you need the rest)"
        case .noBodies:
            return "(contents of \(named) elided to save context — re-read if needed)"
        case .dropped:
            // Terser than `.noBodies`, not merely different: the last level
            // has to be the smallest or it is not a level. Written out the
            // long way first, it was *larger* than the step before it, and
            // the ordering test caught it.
            return "(read \(named))"
        }
    }

    /// What one pass did.
    public struct Report: Sendable, Equatable {
        /// Tool messages this pass changed.
        public var compacted: Int = 0
        /// Characters removed.
        public var charactersSaved: Int = 0
        /// The strongest level applied.
        public var level: Level?

        public var didAnything: Bool { compacted > 0 }
    }

    /// Apply one level to the tool messages in `messages`, oldest first.
    ///
    /// - Parameter keepingRecent: how many messages at the end to leave
    ///   alone. The model is mid-thought about those; compacting the result
    ///   it is about to read is how you make it read the file again.
    public static func compact(
        _ messages: inout [AskMessage],
        to level: Level,
        keepingRecent: Int = 4
    ) -> Report {
        var report = Report()
        let limit = max(0, messages.count - keepingRecent)
        guard limit > 0 else { return report }

        for index in 0..<limit {
            guard messages[index].role == "tool",
                  let content = messages[index].content,
                  !content.isEmpty else { continue }

            let envelope = ToolResultEnvelope.parse(content)
            let sources = envelope?.items.map(\.source) ?? []
            let visible = ToolResultEnvelope.visible(content)

            let replacement: String
            switch level {
            case .shortBodies:
                guard visible.count > shortBodyLimit else { continue }
                replacement = String(visible.prefix(shortBodyLimit))
                    + "\n" + marker(for: sources, level: level)
            case .noBodies:
                guard visible.count > shortBodyLimit / 4 else { continue }
                replacement = marker(for: sources, level: level)
            case .dropped:
                replacement = marker(for: sources, level: level)
            }

            // Below the marker's own length there is nothing to win, and
            // replacing a short result with a longer explanation of its
            // absence would be a loss on both counts.
            guard replacement.count < visible.count else { continue }

            let before = content.count
            messages[index].content = ToolResultEnvelope.replacingVisible(content, with: replacement)
            report.compacted += 1
            report.charactersSaved += before - (messages[index].content?.count ?? 0)
            report.level = max(report.level ?? level, level)
        }
        return report
    }

    /// Compact until the conversation fits, taking the cheapest step first.
    ///
    /// Returns the last report that changed anything, or an empty one when
    /// there was nothing left to shrink — which is the caller's signal that
    /// only summarising will help now.
    public static func compactUntilFits(
        _ messages: inout [AskMessage],
        fits: ([AskMessage]) -> Bool,
        keepingRecent: Int = 4
    ) -> Report {
        var combined = Report()
        for level in Level.allCases {
            if fits(messages) { break }
            let report = compact(&messages, to: level, keepingRecent: keepingRecent)
            combined.compacted += report.compacted
            combined.charactersSaved += report.charactersSaved
            if report.didAnything { combined.level = level }
        }
        return combined
    }
}
