// ============================================================
// AROFormatter.swift
// SOLARO — deterministic indent / cleanup for .aro source
// ============================================================
//
// Triggered by the editor's right-click ▸ Reformat Code item
// (see `AROHoverTextView.menu(for:)`) and reused on save when
// the "Format on save" preference is on.
//
// Rules:
//   * Re-indent each line based on bracket depth — `{`, `[` and
//     `(` open a level; `}`, `]`, `)` close one. Lines that start
//     with a closer are outdented before they print.
//   * Skip bracket counting inside `"…"` string literals and
//     `(* … *)` block comments — feature-set headers like
//     `(Application-Start: Foo) {` close their `(` on the same
//     line, so balanced runs are a no-op for depth.
//   * Block-comment continuation lines (between `(*` and `*)`)
//     pass through with only trailing whitespace stripped — we
//     don't want the formatter rewriting asterisk alignment.
//   * Trailing whitespace stripped.
//   * `..` collapsed to `.` at end of statement — the parser
//     currently fails on the double dot; tracked in
//     gitlab.com/arolang/aro `parser: tolerate double dot`.
//   * Three or more consecutive blank lines collapsed to one.
//   * File ends with exactly one trailing newline.
//
// Indent width is hard-coded to four spaces — that matches every
// example under `Examples/` (run `grep -P "^    " Examples/**.aro
// | head` and the same width comes back) and the canonical
// formatting in the language guide.

import Foundation

enum AROFormatter {
    static let indentWidth = 4

    /// Reformat the entire file. Idempotent: running twice gives
    /// the same output as running once, which is what the caller
    /// in `CodeEditor` relies on when it diffs the result against
    /// the live buffer to decide whether to write back.
    static func format(_ source: String) -> String {
        // Normalize CRLF → LF up front so the line walker stays
        // simple. We re-emit with LF; SOLARO writes UTF-8 LF
        // everywhere else.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let rawLines = normalized.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(rawLines.count)

        var depth = 0
        var inBlockComment = false

        for line in rawLines {
            let trimmedTrailing = stripTrailingWhitespace(line)
            let stripped = trimmedTrailing.trimmingCharacters(
                in: .whitespaces)

            // Inside a `(* … *)` comment: preserve the original
            // leading whitespace (asterisk alignment matters) but
            // strip trailing space and look for the close.
            if inBlockComment {
                output.append(trimmedTrailing)
                if stripped.contains("*)") { inBlockComment = false }
                continue
            }

            if stripped.isEmpty {
                output.append("")
                continue
            }

            // Compute how many closers lead this line so the line
            // itself dedents before it prints, while opens / closes
            // on the same line still affect the depth used by the
            // *next* line.
            let scan = scanBrackets(stripped)
            let lineDepth = max(0, depth - scan.leadingClosers)
            let indent = String(
                repeating: " ",
                count: lineDepth * indentWidth)

            // Collapse `..` (or any run of dots) at the end of the
            // line into a single `.`. We only touch trailing dots
            // outside string literals — the bracket scanner already
            // told us whether the line ended inside a string.
            let body = scan.endedInString
                ? stripped
                : collapseTrailingDots(stripped)

            output.append(indent + body)

            // Block-comment opener that doesn't also close on the
            // same line — flip the flag so continuation lines pass
            // through verbatim.
            if !scan.endedInString && stripped.contains("(*")
                && !stripped.contains("*)") {
                inBlockComment = true
            }

            depth = max(0, depth + scan.delta)
        }

        // Collapse 3+ blank lines down to one, then ensure exactly
        // one trailing newline. The single-blank-line idiom between
        // feature sets is preserved.
        var collapsed: [String] = []
        collapsed.reserveCapacity(output.count)
        var blankRun = 0
        for line in output {
            if line.isEmpty {
                blankRun += 1
                if blankRun <= 1 { collapsed.append(line) }
            } else {
                blankRun = 0
                collapsed.append(line)
            }
        }
        while collapsed.last?.isEmpty == true { collapsed.removeLast() }
        return collapsed.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    private struct BracketScan {
        /// `(opens - closes)` across the whole line, ignoring
        /// brackets inside strings and `(* … *)` comments. Drives
        /// the depth of the *next* line.
        let delta: Int
        /// Count of closers (`}`, `]`, `)`) that lead the line
        /// before any other meaningful token. Used to outdent the
        /// current line so e.g. a lone `}` lands one level shallower
        /// than the body it closes.
        let leadingClosers: Int
        /// True when the line ended inside a `"…"` string literal —
        /// happens with multi-line strings (rare in ARO) and means
        /// we shouldn't touch the trailing dots.
        let endedInString: Bool
    }

    private static func scanBrackets(_ line: String) -> BracketScan {
        var delta = 0
        var leadingClosers = 0
        var sawNonCloser = false
        var inString = false
        var i = line.startIndex
        // Track `(* … *)` opened and closed on the same line — when
        // it crosses line boundaries the outer caller handles it.
        var blockCommentDepth = 0
        while i < line.endIndex {
            let ch = line[i]
            let next = line.index(after: i)

            if blockCommentDepth > 0 {
                if ch == "*" && next < line.endIndex && line[next] == ")" {
                    blockCommentDepth -= 1
                    i = line.index(after: next)
                    continue
                }
                i = next
                continue
            }
            if inString {
                if ch == "\\" && next < line.endIndex {
                    // Skip the escaped character so an embedded
                    // `\"` doesn't toggle string mode.
                    i = line.index(after: next)
                    continue
                }
                if ch == "\"" { inString = false }
                i = next
                continue
            }

            // Not in any skip state.
            if ch == "\"" {
                inString = true
                sawNonCloser = true
                i = next
                continue
            }
            if ch == "(" && next < line.endIndex && line[next] == "*" {
                blockCommentDepth += 1
                sawNonCloser = true
                i = line.index(after: next)
                continue
            }
            switch ch {
            case "{", "[", "(":
                delta += 1
                sawNonCloser = true
            case "}", "]", ")":
                delta -= 1
                if !sawNonCloser { leadingClosers += 1 }
            default:
                if !ch.isWhitespace { sawNonCloser = true }
            }
            i = next
        }
        return BracketScan(
            delta: delta,
            leadingClosers: leadingClosers,
            endedInString: inString)
    }

    private static func stripTrailingWhitespace(_ line: String) -> String {
        var idx = line.endIndex
        while idx > line.startIndex {
            let prev = line.index(before: idx)
            if line[prev].isWhitespace { idx = prev } else { break }
        }
        return String(line[..<idx])
    }

    /// Trim `..` (or longer runs of dots) at the end of a line
    /// down to a single `.`. Walked from the right so we don't
    /// touch ellipses or version numbers earlier in the line — the
    /// double-dot bug only ever shows up at end-of-statement.
    private static func collapseTrailingDots(_ line: String) -> String {
        guard line.hasSuffix("..") else { return line }
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            if line[prev] == "." { end = prev } else { break }
        }
        return String(line[..<end]) + "."
    }
}
