// ============================================================
// HighlightWindowTests.swift
// SOLARO — the highlighter's window (GitLab #750)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Highlight window")
struct HighlightWindowTests {

    /// A document of `lines` identical lines, comfortably past the
    /// full-document limit so the windowing rules actually engage.
    private func longDocument(line: String = "Log \"x\" to the <console>.",
                              lines: Int = 8_000) -> NSString {
        Array(repeating: line, count: lines).joined(separator: "\n") as NSString
    }

    @Test func anOrdinarySourceFileIsHighlightedWhole() {
        // Every real .aro file is far below the limit, so the windowing
        // must be invisible there — same range as before this change.
        let text = "(Application-Start: Demo) {\n    Log \"hi\".\n}\n" as NSString
        let window = HighlightWindow.range(in: text, viewport: nil)
        #expect(window == NSRange(location: 0, length: text.length))
    }

    @Test func anEmptyDocumentHasAnEmptyWindow() {
        let window = HighlightWindow.range(in: "" as NSString, viewport: nil)
        #expect(window.length == 0)
    }

    @Test func aLargeDocumentIsWindowedAroundTheViewport() {
        let text = longDocument()
        let viewport = NSRange(location: text.length / 2, length: 2_000)
        let window = HighlightWindow.range(in: text, viewport: viewport)

        #expect(window.length < text.length)
        // The viewport must be inside what gets painted, with margin.
        #expect(window.location <= viewport.location)
        #expect(window.upperBound >= viewport.upperBound)
        #expect(window.location < viewport.location)
    }

    @Test func theWindowStartsAndEndsOnLineBoundaries() {
        let text = longDocument()
        let viewport = NSRange(location: text.length / 2, length: 2_000)
        let window = HighlightWindow.range(in: text, viewport: viewport)

        // Starting mid-line would colour half a token.
        if window.location > 0 {
            #expect(text.substring(with: NSRange(location: window.location - 1,
                                                 length: 1)) == "\n")
        }
    }

    @Test func aMissingViewportHighlightsTheHeadOfTheDocument() {
        // Before the first layout pass the view cannot say what it shows;
        // the top is what the user is about to see.
        let text = longDocument()
        let window = HighlightWindow.range(in: text, viewport: nil)
        #expect(window.location == 0)
        #expect(window.length < text.length)
    }

    @Test func aWindowOpeningInsideABlockCommentGrowsBackToItsStart() {
        // `(* … *)` spans newlines and the lexer decides what a `(*` opens
        // by reading forward, so a window that began inside one would paint
        // the remainder of the comment as code.
        let comment = "(* " + String(repeating: "note\n", count: 400) + " *)"
        let text = (comment + "\nLog \"after\".\n") as NSString
        let openLocation = text.range(of: "(*").location

        let cutInsideComment = NSRange(location: text.length - 20, length: 10)
        let window = HighlightWindow.expandAcrossBlockComments(cutInsideComment,
                                                               in: text)
        #expect(window.location == openLocation)
    }

    @Test func aWindowClosingInsideABlockCommentGrowsToItsEnd() {
        let comment = "(* " + String(repeating: "note\n", count: 400) + " *)"
        let text = (comment + "\nLog \"after\".\n") as NSString
        let closeEnd = text.range(of: "*)").upperBound

        let cutAtTheOpener = NSRange(location: 0, length: 10)
        let window = HighlightWindow.expandAcrossBlockComments(cutAtTheOpener,
                                                               in: text)
        #expect(window.upperBound == closeEnd)
    }

    @Test func anUnterminatedBlockCommentRunsToTheEndOfTheDocument() {
        let text = "Log \"a\".\n(* never closed\nmore\n" as NSString
        let window = HighlightWindow.expandAcrossBlockComments(
            NSRange(location: 0, length: 12), in: text)
        #expect(window.upperBound == text.length)
    }

    @Test func codeBetweenTwoCommentsIsNotTreatedAsCommented() {
        // The opener before the window is closed, so nothing extends.
        let text = "(* one *)\nLog \"x\".\n(* two *)\n" as NSString
        let codeLine = text.range(of: "Log \"x\".")
        let window = HighlightWindow.expandAcrossBlockComments(codeLine, in: text)
        #expect(window == codeLine)
    }

    @Test func aViewportPastTheEndIsClamped() {
        let text = longDocument()
        let window = HighlightWindow.range(
            in: text,
            viewport: NSRange(location: text.length + 5_000, length: 100))
        #expect(window.upperBound <= text.length)
        #expect(window.location >= 0)
    }
}
