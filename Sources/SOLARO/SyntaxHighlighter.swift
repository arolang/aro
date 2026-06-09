// ============================================================
// SyntaxHighlighter.swift
// SOLARO — ARO source syntax highlighting (Phase 7)
// ============================================================
//
// Tokenises the source via the real AROParser Lexer and applies
// color attributes on top of an NSMutableAttributedString. The
// editor calls `apply(to:source:)` on every text change.
//
// Comments are pre-processed before lexing because the lexer
// strips them; the comment regex covers the standard `(* … *)`
// block form.

import Foundation
import AppKit
import SwiftUI
import AROParser

enum AROSyntaxHighlighter {

    /// Apply syntax-highlight color attributes to `attributed`,
    /// using `source` as the underlying text for offset
    /// resolution. Mutates `attributed` in place — the caller
    /// owns the attribute string and its base font / foreground.
    static func apply(to attributed: NSMutableAttributedString, source: String) {
        let baseColor = NSColor(SolaroColor.textPrimary)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.removeAttribute(.foregroundColor, range: fullRange)
        attributed.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        highlightComments(in: attributed, source: source)
        highlightTokens(in: attributed, source: source)
    }

    // MARK: - Comments

    private static func highlightComments(
        in attributed: NSMutableAttributedString,
        source: String
    ) {
        // (* … *) comments. Greedy across newlines.
        let pattern = "\\(\\*[\\s\\S]*?\\*\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsSource = source as NSString
        let matches = regex.matches(in: source,
                                    range: NSRange(location: 0, length: nsSource.length))
        let commentColor = NSColor(SolaroColor.textTertiary)
        for match in matches {
            attributed.addAttribute(.foregroundColor, value: commentColor, range: match.range)
        }
    }

    // MARK: - Tokens

    private static func highlightTokens(
        in attributed: NSMutableAttributedString,
        source: String
    ) {
        guard let tokens = try? Lexer.tokenize(source) else { return }

        let nsSource = source as NSString
        let nsLength = nsSource.length

        for token in tokens {
            // Compute NSRange from character offsets. Accurate for
            // ASCII source; for emojis the character offset and
            // UTF-16 location can drift, which the editor accepts
            // as a soft failure (no crash, just a slight color
            // misregister on those lines).
            let start = token.span.start.offset
            let end = max(start, token.span.end.offset)
            guard start < nsLength, end <= nsLength else { continue }
            let range = NSRange(location: start, length: end - start)
            guard let color = color(for: token) else { continue }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    /// Map token kinds to colors. Returns `nil` to leave the base
    /// foreground in place (the noop branch keeps the attribute
    /// dictionary smaller).
    private static func color(for token: Token) -> NSColor? {
        switch token.kind {

        case .stringLiteral, .stringSegment:
            return NSColor(Color(red: 0.48, green: 0.83, blue: 0.45))   // green

        case .intLiteral, .floatLiteral:
            return NSColor(Color(red: 0.96, green: 0.78, blue: 0.32))   // amber

        case .true, .false, .nil:
            return NSColor(Color(red: 0.96, green: 0.78, blue: 0.32))

        case .preposition:
            return NSColor(SolaroColor.wireColor(forPreposition: token.lexeme))

        case .article:
            return NSColor(SolaroColor.textTertiary)

        // Control-flow / declaration keywords — accent tint.
        case .publish, .require, .import, .as,
             .if, .then, .else, .when, .match, .case, .otherwise, .where,
             .for, .each, .in, .atKeyword, .parallel, .concurrency,
             .while, .break,
             .type, .enum, .protocol,
             .error, .guard, .defer, .assert, .precondition,
             .and, .or, .not, .is, .exists, .defined, .empty,
             .contains, .matches:
            return NSColor(SolaroColor.accent)

        // Identifiers — see if this looks like a verb (sentence-start
        // capitalised word that maps to a known role) and tint
        // accordingly. Falls through to base color when no role
        // matches.
        case .identifier(let name):
            let role = SolaroColor.roleColor(forVerb: name)
            if role == SolaroColor.textSecondary {
                return nil
            }
            return NSColor(role)

        // Delimiters around identifiers — subtle.
        case .leftAngle, .rightAngle, .colon, .doubleColon:
            return NSColor(SolaroColor.textSecondary)

        // Operators stay base.
        default:
            return nil
        }
    }
}

// NSColor.init(_: Color) is a macOS 14+ SwiftUI bridge — no
// explicit shim needed here.

/// Lightweight regex-based YAML highlighter for the OpenAPI editor.
/// We only need enough colour to make the YAML readable — keys,
/// strings, numbers, booleans, comments. Anchor tags and complex
/// flow constructs aren't covered.
enum YAMLSyntaxHighlighter {
    static func apply(to attributed: NSMutableAttributedString, source: String) {
        let baseColor = NSColor(SolaroColor.textPrimary)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.removeAttribute(.foregroundColor, range: full)
        attributed.addAttribute(.foregroundColor, value: baseColor, range: full)

        paint(pattern: "(^|\\n)\\s*#[^\\n]*",
              in: attributed, source: source,
              color: NSColor(SolaroColor.textTertiary))
        paint(pattern: "^\\s*[A-Za-z0-9_\\-]+(?=\\s*:)",
              in: attributed, source: source,
              color: NSColor(SolaroColor.accent),
              options: [.anchorsMatchLines])
        paint(pattern: "\"[^\"\\n]*\"",
              in: attributed, source: source,
              color: NSColor(Color(red: 0.48, green: 0.83, blue: 0.45)))
        paint(pattern: "'[^'\\n]*'",
              in: attributed, source: source,
              color: NSColor(Color(red: 0.48, green: 0.83, blue: 0.45)))
        paint(pattern: "\\b\\d+(\\.\\d+)?\\b",
              in: attributed, source: source,
              color: NSColor(Color(red: 0.96, green: 0.78, blue: 0.32)))
        paint(pattern: "\\b(true|false|null|~)\\b",
              in: attributed, source: source,
              color: NSColor(Color(red: 0.73, green: 0.47, blue: 0.95)))
    }

    private static func paint(
        pattern: String,
        in attributed: NSMutableAttributedString,
        source: String,
        color: NSColor,
        options: NSRegularExpression.Options = []
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        let full = NSRange(location: 0, length: (source as NSString).length)
        for match in regex.matches(in: source, range: full) {
            attributed.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }
}
