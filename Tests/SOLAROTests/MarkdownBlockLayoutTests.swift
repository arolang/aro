// ============================================================
// MarkdownBlockLayoutTests.swift
// SOLARO — rendered prose is not truncated (GitLab #899, for #895)
// ============================================================
//
// #895 was a correctness bug — text the user could not read — and it was fixed
// by hand and verified by screenshot. Nothing in the suite would have noticed,
// and nothing would notice it coming back.
//
// There are two ways rendered prose gets cut off, and they need different
// tests because only one of them is visible to a measurement:
//
//   1. **A line cap.** `.lineLimit(2)` makes the block's IDEAL height two
//      lines, whatever the text. That is measurable, and the first suite below
//      measures it: a paragraph that needs many lines must be taller than one
//      that needs one.
//
//   2. **A missing `.fixedSize(horizontal: false, vertical: true)`.** This one
//      does NOT change the ideal height — `Text` still reports the full height
//      when asked. It only truncates when a PARENT proposes less, which is
//      what a `LazyVStack` inside a `ScrollView` does when it guesses at a
//      different width than the row finally lays out at. Reproducing that
//      needs the real scroll container, a window, and a layout pass, and
//      detecting the result needs to read back rendered glyphs.
//
// So the second is asserted structurally instead: the modifier is present on
// every text block. That is a test of the implementation rather than of the
// behaviour, and it is written down as such — but #899's complaint is exactly
// "delete any one of those modifiers and the suite stays green", and this is
// what makes that false.

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import SOLARO

@Suite("Rendered markdown is not capped (#899)", .serialized)
@MainActor
struct MarkdownBlockLayoutTests {

    /// Height of one block laid out at a fixed width.
    private func height(of block: BookMarkdownBlock, width: CGFloat) -> CGFloat {
        let view = BookMarkdownBlockView(block: block, style: .editor)
            .frame(width: width)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private let narrow: CGFloat = 320

    @Test("A long paragraph is taller than a short one")
    func longParagraphIsTaller() {
        // The shape of #895: the opening paragraph of Learning notebook 16,
        // which lost its last line. At 320pt this needs many lines; a cap of
        // any kind flattens it towards the short one.
        let short = height(of: .paragraph("Forty shops."), width: narrow)
        let long = height(of: .paragraph("""
            Forty shops, every till printing all day, every shop uploading its \
            receipts to head office at closing time. The consolidated file for \
            one good Saturday is bigger than the RAM of the box that processes \
            it. This is the day Brew & Bytes learns the sentence that organizes \
            everything in this notebook.
            """), width: narrow)

        #expect(short > 0, "a one-line paragraph must have a height at all")
        #expect(long > short * 3,
                "a paragraph needing many lines measured \(long) against \(short) for one line — a line cap would look like this")
    }

    @Test("Height grows with the text, without a ceiling")
    func heightGrowsWithContent() {
        // A cap shows up as a plateau. Three lengths, each strictly taller
        // than the last, is what "no ceiling" looks like from outside.
        let sentence = "Streams do not have a size and values do. "
        let one = height(of: .paragraph(String(repeating: sentence, count: 2)), width: narrow)
        let two = height(of: .paragraph(String(repeating: sentence, count: 8)), width: narrow)
        let three = height(of: .paragraph(String(repeating: sentence, count: 20)), width: narrow)

        #expect(two > one, "8 sentences (\(two)) must exceed 2 (\(one))")
        #expect(three > two, "20 sentences (\(three)) must exceed 8 (\(two))")
    }

    @Test("A narrower column is a taller paragraph")
    func narrowerIsTaller() {
        // The same text wraps more at a smaller width. If this ever stops
        // holding, the block has stopped reacting to its width — which is the
        // other half of how #895 looked.
        let text = String(repeating: "Moving data does not read it. ", count: 12)
        let wide = height(of: .paragraph(text), width: 700)
        let thin = height(of: .paragraph(text), width: 260)
        #expect(thin > wide, "at 260pt it measured \(thin), at 700pt \(wide)")
    }

    @Test("A list with many items is taller than one with a single item")
    func listsGrowToo() {
        let one = height(of: .unorderedList(["first"]), width: narrow)
        let many = height(of: .unorderedList((1...8).map { "item number \($0)" }),
                          width: narrow)
        #expect(many > one * 3, "8 items measured \(many) against \(one) for one")
    }

    @Test("A code block keeps every line")
    func codeBlocksKeepEveryLine() {
        let short = height(of: .codeBlock(language: "aro", body: "Log \"x\" to the <console>."),
                           width: narrow)
        let long = height(of: .codeBlock(
            language: "aro",
            body: (1...12).map { "Log \"line \($0)\" to the <console>." }
                .joined(separator: "\n")), width: narrow)
        #expect(long > short * 4, "12 lines measured \(long) against \(short) for one")
    }
}

// MARK: - The structural half

@Suite("Every markdown text block fixes its height (#899)")
struct MarkdownBlockFixedSizeTests {

    /// `Sources/SOLARO/Books.swift`, found relative to this file so the test
    /// does not depend on where the suite is run from.
    private var booksSource: String {
        get throws {
            let here = URL(fileURLWithPath: #filePath)
            let root = here.deletingLastPathComponent()   // SOLAROTests
                .deletingLastPathComponent()              // Tests
                .deletingLastPathComponent()              // repo root
            return try String(
                contentsOf: root.appendingPathComponent("Sources/SOLARO/Books.swift"),
                encoding: .utf8)
        }
    }

    /// Every renderer in `Books.swift` that puts prose on screen, and the
    /// line it appears on.
    ///
    /// Matched by call rather than by region: paragraphs and lists are in
    /// `BookMarkdownBlockView.body`, headings and HTML are in its private
    /// extension, and table cells are in `BookTableRowView` — three places,
    /// one rule.
    private static let renderers = [
        "inlineText(text)",        // paragraph, blockquote, heading
        "inlineText(item)",        // unordered and ordered list items
        "codeBody(body",           // fenced code
        "Text(attributed)",        // HTML block
        "Text(html)",              // HTML block fallback
        "cellLabel(pair.prose)",   // table cell
    ]

    @Test("Every rendered text block is .fixedSize vertically")
    func everyTextBlockFixesItsHeight() throws {
        // Without it a paragraph loses its last line to an ellipsis: the
        // blocks live in a `LazyVStack` inside a `ScrollView`, which proposes
        // a height it guessed at a different width than the row lays out at,
        // and `Text` reads a short proposal as permission to truncate.
        //
        // This cannot be measured — the ideal height is the same either way —
        // so it is asserted as structure. If this test ever has to be deleted
        // to make a refactor pass, the thing to replace it with is a snapshot
        // of a scrolling notebook, not nothing.
        let lines = try booksSource.components(separatedBy: "\n")
        let fixedSize = ".fixedSize(horizontal: false, vertical: true)"

        for renderer in Self.renderers {
            let sites = lines.indices.filter { lines[$0].contains(renderer) }
            #expect(!sites.isEmpty,
                    "no call to \(renderer) — this test is describing an older view")

            for site in sites {
                // The modifier chain for one view: until the next line that
                // starts a new statement rather than continuing this one.
                let window = lines[site ..< min(site + 10, lines.count)]
                let chain = window.prefix { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty || t.hasPrefix(".") || t.hasPrefix("//") || line == lines[site]
                }
                #expect(chain.contains { $0.contains(fixedSize) },
                        "\(renderer) at Books.swift:\(site + 1) does not fix its height — that block truncates in a notebook")
            }
        }
    }

    @Test("No markdown block carries a line cap")
    func noLineLimitsInTheRenderer() throws {
        // A `.lineLimit` here would cut prose the reader came to read. The
        // measurement suite above catches most spellings; this catches the
        // line being added at all, next to any renderer it does not measure.
        //
        // Scoped to the renderers rather than the whole file, because
        // `Books.swift` also holds the chapter LIST, where a two-line cap on a
        // title in a sidebar row is correct.
        let lines = try booksSource.components(separatedBy: "\n")
        for renderer in Self.renderers {
            for site in lines.indices where lines[site].contains(renderer) {
                let window = lines[site ..< min(site + 10, lines.count)]
                let chain = window.prefix { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.isEmpty || t.hasPrefix(".") || t.hasPrefix("//") || line == lines[site]
                }
                #expect(!chain.contains { $0.contains(".lineLimit") },
                        "\(renderer) at Books.swift:\(site + 1) carries a line cap — that truncates content, not a label (see #895)")
            }
        }
    }
}
