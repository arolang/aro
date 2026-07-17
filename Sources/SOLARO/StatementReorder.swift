// ============================================================
// StatementReorder.swift
// SOLARO — pure text transform for canvas drag-reorder (#376)
// ============================================================
//
// Moves one statement's source lines before / after another
// statement's lines. Kept UI-free so the transform is unit-
// testable without SwiftUI or a running canvas.

import Foundation

enum StatementReorder {
    /// Move the statement covering `source` (offsets into `text`,
    /// typically `span.start.offset ..< span.end.offset`) so its
    /// line block sits immediately before (`insertBefore: true`)
    /// or after the line block covering `target`. Whole lines move
    /// — leading indentation and the trailing newline travel with
    /// the statement, so multi-line statements stay intact.
    ///
    /// Returns nil when either range is out of bounds or the two
    /// line blocks overlap (dropping a statement onto itself).
    /// A positional no-op (e.g. "before the statement I already
    /// precede") returns text equal to the input — callers should
    /// compare before writing so no phantom undo step registers.
    static func movingStatement(
        in text: String,
        source: Range<Int>,
        target: Range<Int>,
        insertBefore: Bool
    ) -> String? {
        let ns = text as NSString
        guard source.lowerBound >= 0, source.upperBound <= ns.length,
              target.lowerBound >= 0, target.upperBound <= ns.length,
              source.upperBound > source.lowerBound,
              target.upperBound > target.lowerBound
        else { return nil }
        let src = lineBlock(for: source, in: ns)
        let dst = lineBlock(for: target, in: ns)
        guard NSIntersectionRange(src, dst).length == 0 else { return nil }

        var statement = ns.substring(with: src)
        // A block without its trailing newline only occurs at EOF;
        // re-add it so the re-inserted statement doesn't fuse with
        // the line that follows the insertion point.
        if !statement.hasSuffix("\n") { statement += "\n" }

        var insertAt = insertBefore ? dst.location : dst.location + dst.length
        let removed = ns.replacingCharacters(in: src, with: "") as NSString
        if insertAt >= src.location + src.length {
            insertAt -= src.length
        }
        guard insertAt <= removed.length else { return nil }
        return removed.replacingCharacters(
            in: NSRange(location: insertAt, length: 0),
            with: statement
        )
    }

    /// Expand a statement's span to whole lines: back to the
    /// character after the previous newline, forward through (and
    /// including) the statement's own trailing newline. Mirrors
    /// the walk in CenterPane's `mutateStatement`.
    private static func lineBlock(
        for range: Range<Int>,
        in text: NSString
    ) -> NSRange {
        var start = range.lowerBound
        while start > 0, text.character(at: start - 1) != 0x0A {
            start -= 1
        }
        var end = range.upperBound
        while end < text.length, text.character(at: end) != 0x0A {
            end += 1
        }
        if end < text.length { end += 1 }  // consume the newline
        return NSRange(location: start, length: end - start)
    }
}
