// ============================================================
// HighlightWindow.swift
// SOLARO — highlight what is on screen, not the whole file (#750)
// ============================================================
//
// `applyHighlight` re-stamped the entire document on every pass: base
// attributes over the full range, a full copy of the source into a new
// attributed string, `Lexer.tokenize` over all of it, then an enumeration
// re-applying every colour range. It is debounced by 40 ms, so that is once
// per typing pause — always the whole file, however large.
//
// Together with the per-keystroke parse (#748) and the per-body graph
// rebuild (#749), that was three full-document passes competing on the main
// actor. `LargeFilePolicy` caps parsing at 512 KB; the highlighter had no
// equivalent ceiling at all below the 4 MB guard.
//
// So the highlighter is given a window instead of the document. The window
// is a range of whole lines around the viewport, and the rules are chosen so
// that ordinary files behave exactly as they did before:
//
//   * At or below `fullDocumentLimit` the window IS the document. Every real
//     `.aro` file is far smaller than 64 KB, so the common path is unchanged
//     and this optimisation cannot introduce a visible seam there.
//   * Above it, the viewport is padded by `margin` characters on each side
//     and snapped out to line boundaries.
//   * Then the window grows to swallow any block comment it cuts. `(* … *)`
//     spans newlines, and both the comment pass and the lexer decide what a
//     `(*` opens by reading forward — so a window starting inside a comment
//     would paint its remainder as code, and a window ending inside one
//     would paint the rest of the file as comment.
//
// Kept separate from `CodeEditor` and free of AppKit so the rules can be
// tested against strings rather than driven through a text view.

import Foundation

/// Which part of a document a highlight pass should cover.
enum HighlightWindow {

    /// At or below this length the window is the whole document.
    ///
    /// Sized so that every plausible source file takes the old path. The
    /// largest file in `Examples/` is a small fraction of this.
    static let fullDocumentLimit = 64 * 1024

    /// Characters of context kept on each side of the viewport, before
    /// snapping to line boundaries.
    ///
    /// Generous on purpose: scrolling a screen or two should not need a new
    /// pass, and the cost is linear in the window, not the file.
    static let margin = 32 * 1024

    private static let commentOpen = "(*"
    private static let commentClose = "*)"

    /// The range to highlight in `text`, given what the view can see.
    ///
    /// `viewport` is the character range currently laid out, or `nil` when
    /// the view cannot say — during the first pass, before layout has run.
    /// A `nil` viewport falls back to the head of the document, which is
    /// what will be on screen a moment later.
    static func range(in text: NSString, viewport: NSRange?) -> NSRange {
        let length = text.length
        let whole = NSRange(location: 0, length: length)
        guard length > fullDocumentLimit else { return whole }

        let seed = clamp(viewport ?? NSRange(location: 0, length: 0), to: length)
        let padded = NSRange(
            location: max(0, seed.location - margin),
            length: min(length, seed.upperBound + margin)
                - max(0, seed.location - margin)
        )
        let lines = text.lineRange(for: clamp(padded, to: length))
        return expandAcrossBlockComments(lines, in: text)
    }

    // MARK: - Block comments

    /// Grow `range` outward so it never begins or ends inside a `(* … *)`.
    static func expandAcrossBlockComments(_ range: NSRange,
                                          in text: NSString) -> NSRange {
        var start = range.location
        var end = range.upperBound

        // Does the text before the window leave a comment open? Compare the
        // last opener with the last closer; an opener that is later wins.
        let prefix = NSRange(location: 0, length: start)
        let lastOpen = text.range(of: commentOpen, options: .backwards,
                                  range: prefix)
        if lastOpen.location != NSNotFound {
            let lastClose = text.range(of: commentClose, options: .backwards,
                                       range: prefix)
            if lastClose.location == NSNotFound
                || lastClose.location < lastOpen.location {
                start = lastOpen.location
            }
        }

        // Does the window itself leave one open? Then run on to its close,
        // or to the end of the document if it never closes.
        let body = NSRange(location: start, length: end - start)
        if unclosedComment(in: body, of: text) {
            let tail = NSRange(location: end, length: text.length - end)
            let close = text.range(of: commentClose, range: tail)
            end = close.location == NSNotFound
                ? text.length
                : close.upperBound
        }

        return NSRange(location: start, length: end - start)
    }

    /// Whether `range` contains more comment openers than closers.
    private static func unclosedComment(in range: NSRange,
                                        of text: NSString) -> Bool {
        count(of: commentOpen, in: range, of: text)
            > count(of: commentClose, in: range, of: text)
    }

    private static func count(of needle: String, in range: NSRange,
                              of text: NSString) -> Int {
        var found = 0
        var search = range
        while search.length > 0 {
            let hit = text.range(of: needle, range: search)
            guard hit.location != NSNotFound else { break }
            found += 1
            let next = hit.upperBound
            search = NSRange(location: next, length: range.upperBound - next)
        }
        return found
    }

    // MARK: - Helpers

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(0, range.location), length)
        return NSRange(location: location,
                       length: min(range.length, length - location))
    }
}
