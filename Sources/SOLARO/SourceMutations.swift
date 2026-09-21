// ============================================================
// SourceMutations.swift
// SOLARO — the splices that rewrite the user's file (#773)
// ============================================================
//
// Nine operations in `CenterPane` computed a byte-range splice into a
// source file and wrote the result back: dropping an action onto the
// canvas, copying or deleting a selection, duplicating or deleting a
// statement, applying an inline edit, moving a statement, appending a
// feature set. Every one of them is a pure function of the text, the
// parsed program and a position — and every one of them lived inside a
// SwiftUI view, where it could not be called from a test.
//
// That is the wrong place for the highest-risk code in the app. These
// splices rewrite the user's file by byte offset; a fencepost error
// here silently eats a line of somebody's program, and the only thing
// standing between that and them is undo. `StatementReorder` already
// shows the right shape — a pure type with its own tests — and this is
// the rest of the same job.
//
// The view keeps the parts that are genuinely view work: deciding which
// URL, reading the live buffer, and handing the result to the write
// path. What it no longer keeps is the arithmetic.
//
// Everything here works in UTF-16 offsets through `NSString`, because
// that is what `SourceSpan` carries and what the editor's own ranges
// use. Mixing that with `String.Index` is exactly the class of bug this
// file exists to make testable.

import Foundation
import AROParser

enum SourceMutations {

    // MARK: - Locating statements

    /// Depth-first search for the statement whose span starts at
    /// `offset`.
    ///
    /// Recurses into loop bodies, because a statement inside a
    /// `for each` has a span of its own and is a canvas node like any
    /// other. The loop *header* is not matched: those nodes render as
    /// decorative brackets rather than editable cards.
    static func locateStatement(in statements: [Statement],
                                matching offset: Int) -> SourceSpan? {
        for statement in statements {
            if let aro = statement as? AROStatement,
               aro.span.start.offset == offset {
                return aro.span
            }
            if let loop = statement as? ForEachLoop,
               let nested = locateStatement(in: loop.body, matching: offset) {
                return nested
            }
            if let loop = statement as? RangeLoop,
               let nested = locateStatement(in: loop.body, matching: offset) {
                return nested
            }
        }
        return nil
    }

    /// Resolve a canvas node ID (`"<file>:<offset>"`) to its span.
    ///
    /// The file part can contain colons, so the offset is taken from
    /// after the *last* one.
    static func span(forNodeID nodeID: String, in program: Program) -> SourceSpan? {
        guard let colon = nodeID.lastIndex(of: ":"),
              let offset = Int(nodeID[nodeID.index(after: colon)...])
        else { return nil }
        for featureSet in program.featureSets {
            if let found = locateStatement(in: featureSet.statements,
                                           matching: offset) {
                return found
            }
        }
        return nil
    }

    /// The span of the statement that starts on `line`.
    ///
    /// The canvas carries a line hint rather than an offset for some
    /// operations, and this is how that becomes a range.
    static func span(startingOnLine line: Int,
                     in program: Program) -> SourceSpan? {
        for featureSet in program.featureSets {
            for statement in featureSet.statements
            where statement.span.start.line == line {
                return statement.span
            }
        }
        return nil
    }

    // MARK: - Whole-line ranges

    /// Grow a statement's span out to whole lines.
    ///
    /// Back to the line start so a removal takes the indentation with
    /// it, and forward past the trailing newline so the gap closes
    /// instead of leaving a blank line behind. Returns `nil` when the
    /// span does not fit the text, which is what a stale program cache
    /// looks like.
    static func lineRange(covering span: Range<Int>,
                          in text: NSString) -> NSRange? {
        let start = span.lowerBound
        let end = span.upperBound
        guard start >= 0, end <= text.length, end > start else { return nil }

        var lineStart = start
        while lineStart > 0, text.character(at: lineStart - 1) != 0x0A {
            lineStart -= 1
        }
        var lineEnd = end
        while lineEnd < text.length, text.character(at: lineEnd) != 0x0A {
            lineEnd += 1
        }
        // Consume the newline, unless this is the last line and there
        // is none — deleting past the end is how you lose a character.
        if lineEnd < text.length { lineEnd += 1 }
        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }

    // MARK: - Mutations

    /// Delete the whole lines a statement occupies.
    static func deletingStatement(in text: String,
                                  span: Range<Int>) -> String? {
        let ns = text as NSString
        guard let range = lineRange(covering: span, in: ns) else { return nil }
        return ns.replacingCharacters(in: range, with: "")
    }

    /// Repeat a statement's lines immediately below themselves.
    static func duplicatingStatement(in text: String,
                                     span: Range<Int>) -> String? {
        let ns = text as NSString
        guard let range = lineRange(covering: span, in: ns) else { return nil }
        let statement = ns.substring(with: range)
        return ns.replacingCharacters(
            in: NSRange(location: range.upperBound, length: 0),
            with: statement)
    }

    /// Delete several statements in one pass.
    ///
    /// Descending order so an earlier span's offsets stay valid while
    /// the list is walked — the reason this cannot simply be the
    /// single-statement version in a loop.
    static func deletingStatements(in text: String,
                                   spans: [Range<Int>]) -> String {
        guard !spans.isEmpty else { return text }
        let ns = (text as NSString).mutableCopy() as! NSMutableString
        for span in spans.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let low = max(0, span.lowerBound)
            let high = max(low, span.upperBound)
            guard high <= ns.length else { continue }
            ns.deleteCharacters(in: NSRange(location: low, length: high - low))
        }
        return ns as String
    }

    /// The source text of the given spans, in document order.
    ///
    /// For copying a canvas selection to the pasteboard as ARO.
    static func extracting(from text: String,
                           spans: [Range<Int>]) -> [String] {
        let ns = text as NSString
        return spans
            .sorted { $0.lowerBound < $1.lowerBound }
            .compactMap { span in
                let low = max(0, span.lowerBound)
                let high = max(low, span.upperBound)
                guard high <= ns.length else { return nil }
                return ns.substring(with: NSRange(location: low,
                                                  length: high - low))
            }
    }

    /// Insert `snippet` at `offset`, indented to match its surroundings.
    static func inserting(_ snippet: String, at offset: Int,
                          in text: String) -> String? {
        let ns = text as NSString
        guard offset >= 0, offset <= ns.length else { return nil }
        let indent = indentation(around: offset, in: ns)
        var indented = snippet
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.isEmpty ? "" : indent + $0 }
            .joined(separator: "\n")
        if !indented.hasSuffix("\n") { indented += "\n" }
        return ns.replacingCharacters(
            in: NSRange(location: offset, length: 0), with: indented)
    }

    /// Append a block at the end of a file, separated by a blank line.
    ///
    /// For a dropped payload that declares its own feature set, which
    /// cannot go inside one.
    static func appending(_ block: String, to text: String) -> String {
        var out = text
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        if !out.isEmpty { out += "\n" }
        out += block
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    // MARK: - Reading the shape of the text

    /// The leading whitespace of the line containing `offset`.
    ///
    /// Four spaces when the line has none, which is what the language's
    /// own examples use.
    static func indentation(around offset: Int, in text: NSString) -> String {
        var index = min(max(0, offset), text.length) - 1
        while index >= 0, text.character(at: index) != 0x0A { index -= 1 }
        let start = index + 1
        var end = start
        while end < text.length {
            let character = text.character(at: end)
            guard character == 0x20 || character == 0x09 else { break }
            end += 1
        }
        guard end > start else { return "    " }
        return text.substring(with: NSRange(location: start,
                                            length: end - start))
    }

    /// Whether a snippet opens a feature set of its own.
    ///
    /// `(Name: Business Activity) {` at the start of some line. Such a
    /// payload cannot be dropped *inside* a feature set, so the caller
    /// appends it instead.
    static func declaresFeatureSet(_ text: String) -> Bool {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("("), trimmed.hasSuffix("{"),
                      let close = trimmed.firstIndex(of: ")")
                else { return false }
                return trimmed[trimmed.startIndex..<close].contains(":")
            }
    }
}
