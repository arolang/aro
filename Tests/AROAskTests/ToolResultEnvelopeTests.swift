// ============================================================
// ToolResultEnvelopeTests.swift
// AROAsk — one shape every tool result can be read through (GitLab #879)
// ============================================================
//
// The envelope has to satisfy two things that pull against each other: the
// model must read exactly what it read before, and the harness must be able
// to find the provenance. So the tests are mostly about what does *not*
// change — the visible output — and about the one thing that must never be
// duplicated into the trailer, the body.

import Testing
import Foundation
@testable import AROAsk

@Suite("Tool result envelope (#879)")
struct ToolResultEnvelopeTests {

    @Test("The visible output is exactly what the tool wrote")
    func visibleOutputIsUnchanged() {
        let encoded = ToolResultEnvelope.file(path: "main.aro", contents: "1\tLog \"hi\".\n").encoded()
        #expect(ToolResultEnvelope.visible(encoded) == "1\tLog \"hi\".")
    }

    /// The trailer exists to make results *smaller*, so a trailer that
    /// repeats the body would be self-defeating — every tool result would
    /// cost twice the tokens to carry provenance that is one path long.
    @Test("The trailer carries provenance, never the body")
    func trailerOmitsBodies() {
        let body = "a body long enough to notice in a token count"
        let encoded = ToolResultEnvelope.file(path: "x.aro", contents: body).encoded()
        let marker = encoded.range(of: "\u{001B}[aro-tool-envelope]")
        let trailer = String(encoded[marker!.lowerBound...])
        #expect(!trailer.contains(body))
        #expect(trailer.contains("x.aro"))
    }

    @Test("A round trip recovers the sources")
    func roundTrip() throws {
        let encoded = ToolResultEnvelope(count: 2, items: [
            ToolResultItem(title: "a.aro", source: "a.aro", body: "one"),
            ToolResultItem(title: "b.aro", source: "b.aro", body: "two"),
        ]).encoded()
        let parsed = try #require(ToolResultEnvelope.parse(encoded))
        #expect(parsed.count == 2)
        #expect(parsed.items.map(\.source) == ["a.aro", "b.aro"])
        #expect(parsed.items.allSatisfy { $0.body == nil })
    }

    /// `count` is what was found; `items` is what was delivered. A search
    /// that matched 240 files and returned 20 has to be able to say so, and
    /// the difference is the only thing telling the model there is more.
    @Test("A truncated result reports what it did not return")
    func countExceedsItems() throws {
        let encoded = ToolResultEnvelope(
            count: 240,
            items: [ToolResultItem(title: "a", source: "a", body: "x")]).encoded()
        let parsed = try #require(ToolResultEnvelope.parse(encoded))
        #expect(parsed.count == 240)
        #expect(parsed.items.count == 1)
    }

    /// A tool whose output is a verdict rather than a list — `aro check`
    /// says "no issues found", which is not an item. Pretending otherwise
    /// would give the compactor a body to drop and a citation footer a
    /// source to print, neither of which exists.
    @Test("A verdict is text, not an item")
    func plainTextHasNoItems() throws {
        let encoded = ToolResultEnvelope.plain("No issues found in 3 file(s)").encoded()
        #expect(ToolResultEnvelope.visible(encoded) == "No issues found in 3 file(s)")
        let parsed = try #require(ToolResultEnvelope.parse(encoded))
        #expect(parsed.items.isEmpty)
        #expect(parsed.count == 0)
    }

    /// An MCP tool's output is the server's business. A result with no
    /// trailer has to keep working untouched — this is what makes the
    /// envelope additive rather than a migration.
    @Test("A result with no envelope passes through unchanged")
    func unenvelopedResultIsUntouched() {
        let raw = "whatever the server sent\nacross two lines"
        #expect(ToolResultEnvelope.parse(raw) == nil)
        #expect(ToolResultEnvelope.visible(raw) == raw)
    }

    @Test("Replacing the visible output keeps the provenance")
    func replacingVisibleKeepsTrailer() throws {
        let encoded = ToolResultEnvelope.file(path: "big.aro", contents: "lots of text").encoded()
        let compacted = ToolResultEnvelope.replacingVisible(encoded, with: "(contents elided)")
        #expect(ToolResultEnvelope.visible(compacted) == "(contents elided)")
        let parsed = try #require(ToolResultEnvelope.parse(compacted))
        #expect(parsed.items.first?.source == "big.aro")
    }
}
