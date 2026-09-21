// ============================================================
// PositionConverter.swift
// AROLSP - Position Conversion between ARO and LSP
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// A per-document line table: where every line starts, in each of the three
/// units this file has to reconcile (GitLab #676).
///
/// ## The three units
///
/// * The **parser** counts Unicode *scalars*. `Lexer.advance()` steps its
///   cursor by one UTF-8 sequence at a time and calls
///   `SourceLocation.advancing(past:)` once per step, so a `column` is
///   "scalars since the start of the line, 1-based" — not grapheme clusters,
///   even though the value it is handed is typed `Character`.
/// * **LSP** counts UTF-16 code units, 0-based. That is fixed by the protocol
///   (`positionEncoding` defaults to `utf-16`).
/// * Swift's `String` iterates **grapheme clusters**, which is what the
///   previous implementation used for its document walk.
///
/// All three agree on ASCII and disagree on almost anything else, in
/// different directions:
///
/// | text        | graphemes | scalars | UTF-16 |
/// |-------------|-----------|---------|--------|
/// | `"e\u{301}"`| 1         | 2       | 2      |
/// | `"🎉"`       | 1         | 1       | 2      |
///
/// So a conversion has to bridge scalars <-> UTF-16 and nothing else. Doing it
/// in grapheme clusters is wrong for the first row; doing it not at all is
/// wrong for the second.
///
/// ## Why a table
///
/// The old `calculateOffset` rescanned the whole document for every position,
/// and `applyChanges` asks for two positions per edit. Building the table is a
/// single scan and every lookup afterwards is a binary search plus a walk of
/// one line.
public struct LineIndex: Sendable {

    /// Where one line begins, recorded in every unit a caller might ask in.
    private struct LineStart: Sendable {
        /// Index of the line's first character in `text`.
        let index: String.Index
        /// UTF-16 code units before the line.
        let utf16: Int
        /// Unicode scalars before the line (what `SourceLocation.offset` counts).
        let scalars: Int
    }

    /// The document this table describes. Stored so a `String.Index` handed
    /// back is always valid against the string it came from.
    public let text: String

    private let lines: [LineStart]

    /// Builds the table in one pass over `text`.
    ///
    /// Line breaks are counted the way `Character.isNewline` sees them, so a
    /// CRLF pair is one break — which is what LSP clients and editors mean by
    /// a line.
    public init(_ text: String) {
        self.text = text

        var lines: [LineStart] = [LineStart(index: text.startIndex, utf16: 0, scalars: 0)]
        var utf16 = 0
        var scalars = 0
        var i = text.startIndex

        while i < text.endIndex {
            let character = text[i]
            utf16 += character.utf16.count
            scalars += character.unicodeScalars.count
            i = text.index(after: i)
            if character.isNewline {
                lines.append(LineStart(index: i, utf16: utf16, scalars: scalars))
            }
        }

        self.lines = lines
    }

    /// Number of lines. A document ending in a newline has a final empty line,
    /// which is what an editor shows and where a cursor can sit.
    public var lineCount: Int { lines.count }

    /// The `String.Index` range of `line`'s content, excluding its line break.
    /// Clamps to the last line for an out-of-range number, so a stale position
    /// from a client that is a keystroke ahead of us lands at the end of the
    /// document instead of trapping.
    private func bounds(ofLine line: Int) -> (start: LineStart, end: String.Index) {
        let clamped = min(max(line, 0), lines.count - 1)
        let start = lines[clamped]
        var end = clamped + 1 < lines.count ? lines[clamped + 1].index : text.endIndex
        // Step back over the line break itself so a column can never point
        // past the visible end of its line.
        while end > start.index, text[text.index(before: end)].isNewline {
            end = text.index(before: end)
        }
        return (start, end)
    }

    /// The `String.Index` an LSP position names.
    ///
    /// `position.character` is a UTF-16 offset into its line; a value past the
    /// end of the line clamps to the end of the line, and one that would land
    /// inside a surrogate pair rounds down to the start of that character —
    /// both of which LSP explicitly allows a client to send.
    public func index(of position: Position) -> String.Index {
        let (start, end) = bounds(ofLine: position.line)
        guard position.character > 0 else { return start.index }

        var remaining = position.character
        var i = start.index
        while i < end {
            let width = text[i].utf16.count
            if remaining < width { return i }   // inside a surrogate pair: round down
            remaining -= width
            i = text.index(after: i)
            if remaining == 0 { return i }
        }
        return end
    }

    /// The `String.Index` an ARO source location names — `line` and `column`
    /// 1-based, `column` counted in Unicode scalars.
    public func index(of location: SourceLocation) -> String.Index {
        let (start, end) = bounds(ofLine: location.line - 1)
        guard location.column > 1 else { return start.index }

        var remaining = location.column - 1
        var i = start.index
        while i < end, remaining > 0 {
            let width = text[i].unicodeScalars.count
            if remaining < width { return i }   // mid-cluster: round down
            remaining -= width
            i = text.index(after: i)
        }
        return i
    }

    /// UTF-16 offset of `index` within its line — the `character` half of an
    /// LSP position.
    public func utf16Column(at index: String.Index, line: Int) -> Int {
        let (start, _) = bounds(ofLine: line)
        guard index > start.index else { return 0 }
        return text.utf16.distance(from: start.index, to: index)
    }

    /// Scalar column (1-based) of `index` within its line — the `column` half
    /// of an ARO `SourceLocation`.
    public func scalarColumn(at index: String.Index, line: Int) -> Int {
        let (start, _) = bounds(ofLine: line)
        guard index > start.index else { return 1 }
        return text.unicodeScalars.distance(from: start.index, to: index) + 1
    }

    /// Unicode scalars from the start of the document to `index` — what
    /// `SourceLocation.offset` records.
    public func scalarOffset(at index: String.Index) -> Int {
        text.unicodeScalars.distance(from: text.startIndex, to: index)
    }

    /// UTF-8 bytes from the start of the document to `index` — what
    /// `SourceLocation.byteOffset` records.
    public func byteOffset(at index: String.Index) -> Int {
        text.utf8.distance(from: text.startIndex, to: index)
    }
}

/// Converts between ARO source positions and LSP positions.
///
/// LSP is 0-based and counts UTF-16 code units; ARO is 1-based and counts
/// Unicode scalars (see `LineIndex` for why, and for what used to go wrong).
/// Every conversion therefore needs the document text: the offsets only mean
/// the same thing when you can see the characters between them.
public struct PositionConverter {

    // MARK: - ARO -> LSP

    /// Convert an ARO `SourceLocation` to an LSP `Position` within `document`.
    public static func toLSP(_ location: SourceLocation, in document: String) -> Position {
        toLSP(location, using: LineIndex(document))
    }

    /// Convert an ARO `SourceLocation` using an already-built line table.
    public static func toLSP(_ location: SourceLocation, using index: LineIndex) -> Position {
        let line = max(location.line - 1, 0)
        let stringIndex = index.index(of: location)
        return Position(line: line, character: index.utf16Column(at: stringIndex, line: line))
    }

    /// Convert an ARO `SourceSpan` to an LSP `LSPRange` within `document`.
    public static func toLSP(_ span: SourceSpan, in document: String) -> LSPRange {
        toLSP(span, using: LineIndex(document))
    }

    /// Convert an ARO `SourceSpan` using an already-built line table.
    public static func toLSP(_ span: SourceSpan, using index: LineIndex) -> LSPRange {
        LSPRange(start: toLSP(span.start, using: index), end: toLSP(span.end, using: index))
    }

    // MARK: - LSP -> ARO

    /// Convert an LSP `Position` to an ARO `SourceLocation` within `document`.
    public static func fromLSP(_ position: Position, in document: String) -> SourceLocation {
        fromLSP(position, using: LineIndex(document))
    }

    /// Convert an LSP `Position` using an already-built line table.
    ///
    /// The resulting location carries a real `offset` and `byteOffset` as well
    /// as line/column, so consumers that compare against lexer-produced
    /// locations (which fill all four) get consistent answers.
    public static func fromLSP(_ position: Position, using index: LineIndex) -> SourceLocation {
        let stringIndex = index.index(of: position)
        return SourceLocation(
            line: position.line + 1,
            column: index.scalarColumn(at: stringIndex, line: position.line),
            offset: index.scalarOffset(at: stringIndex),
            byteOffset: index.byteOffset(at: stringIndex)
        )
    }

    /// Convert an LSP `LSPRange` to an ARO `SourceSpan` within `document`.
    public static func fromLSP(_ range: LSPRange, in document: String) -> SourceSpan {
        fromLSP(range, using: LineIndex(document))
    }

    /// Convert an LSP `LSPRange` using an already-built line table.
    public static func fromLSP(_ range: LSPRange, using index: LineIndex) -> SourceSpan {
        SourceSpan(start: fromLSP(range.start, using: index), end: fromLSP(range.end, using: index))
    }

    // MARK: - Offsets

    /// The `String.Index` in `document` that an LSP position names.
    ///
    /// Prefer this over an integer offset: it is the only form that cannot be
    /// re-interpreted in the wrong unit by the caller.
    public static func stringIndex(of position: Position, in document: String) -> String.Index {
        LineIndex(document).index(of: position)
    }

    /// Grapheme-cluster offset of an LSP position in `document`.
    ///
    /// Kept because callers that slice with `String.index(_:offsetBy:)` need
    /// this unit and no other. It is derived from the UTF-16-correct
    /// `String.Index`, so unlike the version this replaced it agrees with the
    /// protocol about where the position is.
    public static func calculateOffset(_ position: Position, in document: String) -> Int {
        document.distance(from: document.startIndex, to: stringIndex(of: position, in: document))
    }
}

#endif
