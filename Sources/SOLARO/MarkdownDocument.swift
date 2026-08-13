// ============================================================
// MarkdownDocument.swift
// SOLARO — positional markdown model for the inline editor (#488)
// ============================================================
//
// The hybrid markdown editor renders every block of a `.md` file
// except the one the caret sits in, which shows raw source. That
// only works if we can map a caret to a block and a block back to
// its exact bytes in the file — which is what this file adds on
// top of `BookMarkdownParser`.
//
// Invariants, in order of importance:
//
//   1. `lines` is the single source of truth. Blocks are derived.
//      `text` is `lines.joined(separator: "\n")`, which round-trips
//      any input byte-for-byte (splitting on "\n" and rejoining is
//      the identity, including for CRLF files — the "\r" rides
//      along at the end of each line).
//   2. Blocks are line-granular. Every markdown block this parser
//      knows starts at a line boundary and ends at one, so a block
//      is addressed by a half-open `Range<Int>` of line indices.
//   3. Blank separator lines belong to no block. The ranges
//      therefore do *not* tile the document; they are anchors, and
//      an edit always goes through `lines`.
//
// No SwiftUI here — the whole model is unit-testable.

import Foundation

/// One parsed block plus the source lines it came from.
struct MarkdownSourceBlock: Identifiable, Equatable {
    /// Stable across re-parses of *other* regions of the document,
    /// so SwiftUI keeps view identity (and scroll position) for
    /// blocks the user isn't touching. Assigned by
    /// `MarkdownDocument`; the parser leaves it at 0.
    var id: Int = 0
    /// The rendered representation.
    var block: BookMarkdownBlock
    /// Half-open range of source line indices this block spans.
    var lineRange: Range<Int>
}

/// A markdown file as an editable buffer plus its block index.
struct MarkdownDocument: Equatable {

    /// Source lines, split on "\n" with empties preserved.
    private(set) var lines: [String]
    /// Parsed blocks, in document order, with line ranges into
    /// `lines`.
    private(set) var blocks: [MarkdownSourceBlock]
    /// Monotonic id source for block identity.
    private var nextID: Int = 0

    // MARK: - Construction

    init(text: String) {
        lines = Self.split(text)
        blocks = []
        blocks = stamp(BookMarkdownParser.parseSourceBlocks(text))
    }

    /// Reassemble the buffer. Guaranteed byte-identical to the text
    /// this document was built from as long as no edit was applied.
    var text: String { lines.joined(separator: "\n") }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Assign fresh ids to a freshly parsed run of blocks.
    private mutating func stamp(
        _ parsed: [MarkdownSourceBlock]
    ) -> [MarkdownSourceBlock] {
        parsed.map { block in
            var copy = block
            copy.id = nextID
            nextID += 1
            return copy
        }
    }

    // MARK: - Lookup

    /// Raw markdown for block `index`, exactly as it appears in the
    /// buffer. Feeding this back through `replaceSource(at:with:)`
    /// unchanged is a no-op on `text` — the round-trip guarantee the
    /// editor relies on when the caret merely visits a block.
    func rawSource(at index: Int) -> String {
        guard blocks.indices.contains(index) else { return "" }
        return lines[blocks[index].lineRange].joined(separator: "\n")
    }

    /// Character offset of the first character of `line` within
    /// `text`. `line == lines.count` returns the end offset.
    func characterOffset(ofLine line: Int) -> Int {
        var offset = 0
        for idx in 0..<min(line, lines.count) {
            offset += lines[idx].count + 1  // + the "\n" separator
        }
        return line >= lines.count && !lines.isEmpty
            ? offset - 1   // no separator after the final line
            : offset
    }

    /// The block's span as character offsets into `text` — the
    /// "source range in the underlying text buffer" the editor maps
    /// a caret offset onto.
    func characterRange(at index: Int) -> Range<Int> {
        guard blocks.indices.contains(index) else { return 0..<0 }
        let range = blocks[index].lineRange
        let start = characterOffset(ofLine: range.lowerBound)
        return start..<(start + rawSource(at: index).count)
    }

    /// The block containing `line`, or nil when the line is a blank
    /// separator between blocks.
    func blockIndex(forLine line: Int) -> Int? {
        blocks.firstIndex { $0.lineRange.contains(line) }
    }

    /// The block containing `line`, or — for a blank separator or an
    /// out-of-range line — the nearest block at or before it, else
    /// the first block. Used to re-resolve the active block after a
    /// re-parse may have moved boundaries under the caret.
    func nearestBlockIndex(toLine line: Int) -> Int? {
        if blocks.isEmpty { return nil }
        if let exact = blockIndex(forLine: line) { return exact }
        var candidate: Int? = nil
        for (idx, block) in blocks.enumerated()
        where block.lineRange.lowerBound <= line {
            candidate = idx
        }
        return candidate ?? 0
    }

    /// Absolute (line, column) for a caret sitting `offset`
    /// characters into block `index`. Buffer coordinates survive a
    /// re-parse, which block indices do not — undo snapshots and
    /// scroll anchors store this, not an index.
    func caretLineColumn(
        blockIndex index: Int,
        offset: Int
    ) -> (line: Int, column: Int) {
        guard blocks.indices.contains(index) else { return (0, 0) }
        let start = blocks[index].lineRange.lowerBound
        var remaining = max(0, offset)
        var line = start
        let source = lines[blocks[index].lineRange]
        for text in source {
            if remaining <= text.count { break }
            remaining -= text.count + 1
            line += 1
        }
        return (min(line, max(0, lines.count - 1)), remaining)
    }

    /// Inverse of `caretLineColumn` — resolve a buffer position back
    /// to a block and an offset inside it.
    func caretPosition(line: Int, column: Int) -> MarkdownCaretPosition? {
        guard let index = nearestBlockIndex(toLine: line) else { return nil }
        let range = blocks[index].lineRange
        var offset = 0
        for idx in range.lowerBound..<min(line, range.upperBound) {
            offset += lines[idx].count + 1
        }
        if range.contains(line) {
            offset += min(column, lines[line].count)
        } else {
            offset = rawSource(at: index).count
        }
        return MarkdownCaretPosition(blockIndex: index, offset: offset)
    }

    // MARK: - Editing

    /// Splice `newSource` over block `index`'s lines *without*
    /// re-splitting. Called on every keystroke in the active block:
    /// the buffer stays authoritative (so ⌘S writes what was typed)
    /// while the block list stays stable, so a half-typed `#` or a
    /// fresh blank line doesn't reshuffle the document under the
    /// caret. `reparse(around:)` does the re-split once the caret
    /// leaves.
    @discardableResult
    mutating func replaceSource(at index: Int, with newSource: String) -> Bool {
        guard blocks.indices.contains(index) else { return false }
        let oldRange = blocks[index].lineRange
        let newLines = Self.split(newSource)
        guard lines[oldRange] != ArraySlice(newLines) else { return false }
        lines.replaceSubrange(oldRange, with: newLines)
        let delta = newLines.count - oldRange.count
        blocks[index].lineRange =
            oldRange.lowerBound..<(oldRange.lowerBound + newLines.count)
        shiftBlocks(after: index, by: delta)
        return true
    }

    /// Re-parse the region around block `index` and splice the
    /// resulting blocks back in — the structural half of an edit
    /// (paragraph split by a blank line, `# ` promoting a paragraph
    /// to a heading, two paragraphs merged).
    ///
    /// Bounded on purpose: only the affected region is re-parsed,
    /// and blocks after it just get their line ranges shifted. A
    /// 10k-line file costs the same as a 50-line one for a
    /// single-paragraph edit.
    mutating func reparse(around index: Int) {
        guard blocks.indices.contains(index) else { return }
        let region = regionBounds(around: blocks[index].lineRange)
        reparseRegion(region)
    }

    /// Same as `reparse(around:)` but anchored on a line, for the
    /// case where the edit deleted the block entirely.
    mutating func reparse(aroundLine line: Int) {
        let clamped = max(0, min(line, max(0, lines.count - 1)))
        reparseRegion(regionBounds(around: clamped..<(clamped + 1)))
    }

    private mutating func reparseRegion(_ region: Range<Int>) {
        let slice = lines[region].joined(separator: "\n")
        let parsed = BookMarkdownParser.parseSourceBlocks(
            slice, lineOffset: region.lowerBound)

        // Blocks the region replaces: every block overlapping it.
        let replaced = blocks.indices.filter {
            blocks[$0].lineRange.overlaps(region)
        }
        let insertAt = replaced.first
            ?? blocks.firstIndex { $0.lineRange.lowerBound >= region.upperBound }
            ?? blocks.count

        // Reuse the ids of the blocks being replaced, positionally.
        // The overwhelmingly common edit is 1 block → 1 block, where
        // this keeps SwiftUI identity (and the scroll position)
        // exactly as it was.
        var fresh: [MarkdownSourceBlock] = []
        for (offset, var block) in parsed.enumerated() {
            if offset < replaced.count {
                block.id = blocks[replaced[offset]].id
            } else {
                block.id = nextID
                nextID += 1
            }
            fresh.append(block)
        }

        if let first = replaced.first, let last = replaced.last {
            blocks.replaceSubrange(first...last, with: fresh)
        } else {
            blocks.insert(contentsOf: fresh, at: insertAt)
        }
    }

    /// Grow `range` outwards to the nearest blank lines, then keep
    /// growing while it clips a block in half. The blank-line walk
    /// is what makes "type a blank line → two paragraphs" and
    /// "delete a blank line → one paragraph" work; the block-cover
    /// step is what stops a fenced code block (whose interior may
    /// contain blank lines) from being re-parsed from its middle.
    private func regionBounds(around range: Range<Int>) -> Range<Int> {
        var lower = min(range.lowerBound, lines.count)
        var upper = min(range.upperBound, lines.count)
        while lower > 0, !lines[lower - 1].trimmingCharacters(
            in: .whitespaces).isEmpty { lower -= 1 }
        while upper < lines.count, !lines[upper].trimmingCharacters(
            in: .whitespaces).isEmpty { upper += 1 }

        var changed = true
        while changed {
            changed = false
            for block in blocks where block.lineRange.overlaps(lower..<upper) {
                if block.lineRange.lowerBound < lower {
                    lower = block.lineRange.lowerBound
                    changed = true
                }
                if block.lineRange.upperBound > upper {
                    upper = min(block.lineRange.upperBound, lines.count)
                    changed = true
                }
            }
        }
        return lower..<upper
    }

    private mutating func shiftBlocks(after index: Int, by delta: Int) {
        guard delta != 0 else { return }
        for idx in blocks.indices where idx > index {
            let lower = blocks[idx].lineRange.lowerBound + delta
            let upper = blocks[idx].lineRange.upperBound + delta
            blocks[idx].lineRange = lower..<upper
        }
    }

    // MARK: - Structural edits across block boundaries

    /// Backspace at offset 0 of block `index`: fold it into the
    /// previous block. Drops the blank separator lines between the
    /// two; if they were already adjacent, joins the boundary lines
    /// so the caret behaves like it does in a plain text editor.
    ///
    /// Returns where the caret should land — the block index it
    /// ended up in and the character offset inside that block — or
    /// nil when there is no previous block to merge with.
    @discardableResult
    mutating func mergeWithPrevious(at index: Int) -> MarkdownCaretPosition? {
        guard index > 0, blocks.indices.contains(index) else { return nil }
        let previous = blocks[index - 1]
        let current = blocks[index]
        let caretOffset = rawSource(at: index - 1).count
        let gap = previous.lineRange.upperBound..<current.lineRange.lowerBound

        if gap.isEmpty {
            // Already adjacent (heading directly above a paragraph,
            // say): splice the two boundary lines into one.
            let joinAt = previous.lineRange.upperBound - 1
            lines[joinAt] += lines[current.lineRange.lowerBound]
            lines.remove(at: current.lineRange.lowerBound)
        } else {
            lines.removeSubrange(gap)
        }

        // Ranges are stale now; re-derive the whole affected region
        // from the buffer rather than trying to patch them.
        let anchor = previous.lineRange.lowerBound
        rebuildBlocks()
        guard let landed = nearestBlockIndex(toLine: anchor) else { return nil }
        return MarkdownCaretPosition(blockIndex: landed, offset: caretOffset)
    }

    /// Forward-delete at the end of block `index`: fold the *next*
    /// block into this one. Mirrors `mergeWithPrevious`.
    @discardableResult
    mutating func mergeWithNext(at index: Int) -> MarkdownCaretPosition? {
        guard blocks.indices.contains(index + 1) else { return nil }
        return mergeWithPrevious(at: index + 1)
    }

    /// Full re-parse. Only used by the merge paths, where line
    /// ranges on both sides of the seam move and an incremental
    /// splice would be more code than it is worth.
    private mutating func rebuildBlocks() {
        let previous = blocks
        var rebuilt = BookMarkdownParser.parseSourceBlocks(text)

        // Carry ids over so untouched blocks keep their SwiftUI
        // identity — otherwise every block below the seam re-renders
        // and the scroll position jumps. Match the unchanged tail
        // from the end and the unchanged head from the front; only
        // the blocks in between (the seam itself) get fresh ids.
        var head = 0
        while head < rebuilt.count, head < previous.count,
              rebuilt[head].block == previous[head].block {
            rebuilt[head].id = previous[head].id
            head += 1
        }
        var tail = 0
        while tail < rebuilt.count - head, tail < previous.count - head,
              rebuilt[rebuilt.count - 1 - tail].block
                == previous[previous.count - 1 - tail].block {
            rebuilt[rebuilt.count - 1 - tail].id =
                previous[previous.count - 1 - tail].id
            tail += 1
        }
        for idx in head..<(rebuilt.count - tail) {
            rebuilt[idx].id = nextID
            nextID += 1
        }
        blocks = rebuilt
    }
}

/// Where the caret sits: which block, and how many characters into
/// that block's raw source.
struct MarkdownCaretPosition: Equatable {
    var blockIndex: Int
    var offset: Int
}

/// How the caret should be placed when a block is activated.
enum MarkdownCaretEntry: Equatable {
    /// Explicit character offset into the block's raw source.
    case offset(Int)
    /// Entering from above (↓ / →): land on the first line at this
    /// column, clamped to that line's length.
    case firstLine(column: Int)
    /// Entering from below (↑ / ←): land on the last line at this
    /// column, clamped.
    case lastLine(column: Int)
    /// Caret at the very end of the block.
    case end

    /// Resolve to a character offset inside `source`.
    func resolve(in source: String) -> Int {
        switch self {
        case .offset(let value):
            return max(0, min(value, source.count))
        case .end:
            return source.count
        case .firstLine(let column):
            let first = source.components(separatedBy: "\n").first ?? ""
            return min(column, first.count)
        case .lastLine(let column):
            let all = source.components(separatedBy: "\n")
            let last = all.last ?? ""
            let base = source.count - last.count
            return base + min(column, last.count)
        }
    }
}

// MARK: - Undo

/// A restorable editor state: the whole buffer plus where the caret
/// was. Snapshotting the buffer (rather than per-block text-view
/// undo) is what makes ⌘Z work across block boundaries and across
/// render / un-render transitions — the acceptance criterion a
/// per-`NSTextView` UndoManager cannot meet, because each of those
/// managers dies with its block.
struct MarkdownSnapshot: Equatable {
    var text: String
    /// Line the caret was on, so the state can be restored even
    /// though re-parsing may have renumbered blocks.
    var caretLine: Int
    var caretColumn: Int

    init(text: String, caretLine: Int = 0, caretColumn: Int = 0) {
        self.text = text
        self.caretLine = caretLine
        self.caretColumn = caretColumn
    }
}

/// Undo/redo over whole-buffer snapshots, with typing coalesced so
/// one ⌘Z doesn't walk back a single character.
struct MarkdownUndoStack: Equatable {
    /// Consecutive edits sharing a key inside `coalesceWindow`
    /// collapse into the snapshot taken before the run started.
    static let coalesceWindow: TimeInterval = 0.6

    private var undoStack: [MarkdownSnapshot] = []
    private var redoStack: [MarkdownSnapshot] = []
    private var lastKey: String? = nil
    private var lastRecordedAt: TimeInterval = -.greatestFiniteMagnitude

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Record the state *before* a mutation. `key` identifies the
    /// edit run (the active block's id is the natural choice);
    /// pass nil for structural edits that should always be their
    /// own undo step.
    mutating func record(
        _ snapshot: MarkdownSnapshot,
        key: String?,
        at now: TimeInterval
    ) {
        redoStack.removeAll()
        if let key, key == lastKey, now - lastRecordedAt < Self.coalesceWindow {
            lastRecordedAt = now
            return
        }
        if undoStack.last?.text == snapshot.text, key != nil, key == lastKey {
            lastRecordedAt = now
            return
        }
        undoStack.append(snapshot)
        lastKey = key
        lastRecordedAt = now
    }

    /// Force the next `record` to start a fresh undo step even if it
    /// lands inside the coalesce window. Called when the caret
    /// leaves a block, so "typed in A, typed in B" is two steps.
    mutating func breakCoalescing() {
        lastKey = nil
        lastRecordedAt = -.greatestFiniteMagnitude
    }

    mutating func undo(current: MarkdownSnapshot) -> MarkdownSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        breakCoalescing()
        return previous
    }

    mutating func redo(current: MarkdownSnapshot) -> MarkdownSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        breakCoalescing()
        return next
    }
}

// MARK: - File-type routing

enum MarkdownFile {
    /// Extensions the inline markdown editor claims (#488).
    static let extensions: Set<String> = ["md", "markdown"]

    static func isMarkdown(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
