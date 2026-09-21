// ============================================================
// DedupeGuardTests.swift
// ARO Runtime - the handler-level dedupe declaration (GitLab #727)
// ============================================================
//
// The execution engine used to de-duplicate one event by name: an event called
// `CrawlPage` whose payload happened to be keyed `data` had its `url` dropped
// on a second sighting. Nothing else could ask for it, the compiled runtime did
// not do it at all, and the shape the Book documented —
// `Emit a <CrawlPage: event> with { url: … }` — spreads the payload and so
// never reached the check in the first place.
//
// `Handler<dedupe:url>` is that behaviour with the name taken out of it:
// any handler of any event declares the field that identifies its events.

import Testing
@testable import ARORuntime

@Suite("Dedupe guard (ARO-0007 §3.6)")
struct DedupeGuardTests {

    // MARK: - Declaring the field

    @Test("A handler declares the field that identifies its events")
    func parsesTheField() {
        #expect(DedupeGuard.field(in: "CrawlPage Handler<dedupe:url>") == "url")
        #expect(DedupeGuard.field(in: "PageFetched Handler<dedupe: page.url >") == "page.url")
    }

    @Test("A handler that declares nothing has no identity field")
    func absentByDefault() {
        #expect(DedupeGuard.field(in: "CrawlPage Handler") == nil)
        #expect(DedupeGuard.field(in: "OrderUpdated Handler<status:paid>") == nil)
        #expect(DedupeGuard.field(in: "status StateObserver<draft_to_placed>") == nil)
        #expect(DedupeGuard.field(in: "CrawlPage Handler<dedupe:>") == nil)
    }

    @Test("Dedupe combines with state guards")
    func combinesWithStateGuards() {
        let activity = "CrawlPage Handler<status:new;dedupe:url>"
        #expect(DedupeGuard.field(in: activity) == "url")

        // The dedupe component is a declaration, not a field comparison: read as
        // a state guard it would ask every event for a field called "dedupe"
        // and match nothing.
        let guards = StateGuardSet.parse(from: activity)
        #expect(guards.count == 1)
        #expect(guards.allMatch(payload: ["status": "new"]))
        #expect(!guards.allMatch(payload: ["status": "old"]))
    }

    @Test("A dedupe declaration on its own leaves no state guards behind")
    func dedupeAloneIsNotAStateGuard() {
        let guards = StateGuardSet.parse(from: "CrawlPage Handler<dedupe:url>")
        #expect(guards.isEmpty)
        #expect(guards.allMatch(payload: ["url": "http://example.com/"]))
    }

    // MARK: - Identifying an event

    @Test("The field is read from the payload Emit actually produces")
    func readsASpreadPayload() {
        // `Emit a <CrawlPage: event> with { url: …, base: … }` spreads the
        // object literal across the payload.
        let payload: [String: any Sendable] = [
            "url": "http://example.com/",
            "base": "example.com"
        ]
        #expect(DedupeGuard.identity(ofField: "url", in: payload) == "http://example.com/")
    }

    @Test("A payload wrapped under the emitted variable's name is looked through")
    func readsAWrappedPayload() {
        // `Emit a <CrawlPage: event> with <page>` wraps the value under "page".
        let payload: [String: any Sendable] = [
            "page": ["url": "http://example.com/", "depth": 2] as [String: any Sendable]
        ]
        #expect(DedupeGuard.identity(ofField: "url", in: payload) == "http://example.com/")
    }

    @Test("A dotted path addresses a nested field directly")
    func readsADottedPath() {
        let payload: [String: any Sendable] = [
            "page": ["link": ["url": "http://example.com/"] as [String: any Sendable]] as [String: any Sendable]
        ]
        #expect(DedupeGuard.identity(ofField: "page.link.url", in: payload) == "http://example.com/")
    }

    @Test("A non-string field still identifies an event")
    func rendersNonStrings() {
        #expect(DedupeGuard.identity(ofField: "id", in: ["id": 42]) == "42")
    }

    @Test("An event without the field has no identity and is never dropped")
    func missingFieldHasNoIdentity() {
        #expect(DedupeGuard.identity(ofField: "url", in: ["base": "example.com"]) == nil)
        #expect(DedupeGuard.identity(ofField: "url", in: [:]) == nil)
    }

    // MARK: - What the store does with it

    @Test("The first sighting passes and the rest are dropped")
    func dropsRepeats() {
        let store = VisitedURLStore(maxSize: 100)
        #expect(store.tryInsert("http://a.example/"))
        #expect(!store.tryInsert("http://a.example/"))
        #expect(store.tryInsert("http://b.example/"))
    }
}
