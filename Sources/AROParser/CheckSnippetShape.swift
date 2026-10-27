// ============================================================
// CheckSnippetShape.swift
// AROParser — what shape a source fragment is
// GitLab #845
// ============================================================
//
// `aro check --syntax`, the REPL and the Jupyter kernel (ARO-0091) all take a
// fragment and have to decide whether it is a list of statements (which needs
// wrapping in a feature set before the parser will take it) or one or more
// feature sets (which must not be wrapped, or the wrapper nests them and the
// parser reports the header as a stray `(`).
//
// The decision was made by matching a feature-set header at the very start of
// the text. `(* … *)` before a feature set is the house style, so nearly every
// documentation block that introduces one failed the test, got wrapped as a
// statement body, and reported "Expected action verb (e.g., Extract, Filter,
// Return), but got (" — against a wrapper named `SyntaxOnly_Check` that the
// author never wrote.
//
// It lives here rather than in the CLI because all three callers are outside
// the CLI, and because a rule about the shape of ARO source belongs with the
// parser.

import Foundation

public enum CheckSnippetShape {

    /// The source with any leading `(* … *)` comments and whitespace removed,
    /// so a shape test sees the first real token.
    ///
    /// Comments do not nest in ARO, so the first `*)` closes the block and
    /// scanning for it is exact rather than a heuristic. An unterminated
    /// comment is returned as-is: there is no first real token to find, and
    /// guessing at the shape would replace the parser's accurate complaint
    /// with an invented one.
    public static func skippingLeadingComments(_ source: String) -> String {
        var rest = Substring(source)
        while true {
            rest = rest.drop(while: { $0.isWhitespace })
            guard rest.hasPrefix("(*") else { return String(rest) }
            guard let close = rest.range(of: "*)") else { return String(rest) }
            rest = rest[close.upperBound...]
        }
    }
}
