// ============================================================
// REPLEventDispatchTests.swift
// AROCLI — event dispatch in interactive sessions (ARO-0091)
// ============================================================
//
// A `{EventName} Handler` defined in a session must actually fire
// when a later input emits — the whole point of the feature. The
// observable used here is a repository the handler stores into:
// repositories live on the runtime's store, so a follow-up
// statement can read back what the handler did, without touching
// stdout capture (which belongs to the server layer, not the
// session). The store is process-global, so every test uses its
// own repository name and its own event type — tests must not see
// each other's pings.

import Testing
import Foundation
import ARORuntime
@testable import AROCLI

@Suite("REPL event dispatch", .serialized)
struct REPLEventDispatchTests {

    /// One isolated dispatch playground: unique event type and
    /// repository name, so parallel/serial test order can't leak
    /// state between cases.
    private struct Playground {
        let session = REPLSession()
        /// A name fragment unique to this Playground.
        ///
        /// This used to filter letters out of a UUID's first eight
        /// characters — and those eight can be all digits, which left
        /// the token EMPTY. Two Playgrounds then shared one repository
        /// name and saw each other's events, so a test read a payload
        /// another test had stored. Draw from two whole UUIDs and keep
        /// a leading letter: never empty, effectively never repeated.
        let token = "p" + String((UUID().uuidString + UUID().uuidString)
            .lowercased()
            .filter { $0.isLetter }
            .prefix(10))
        var eventType: String { "Ping\(token.capitalized)" }
        var repository: String { "ping\(token)-repository" }

        func defineRecorder(
            name: String = "RecorderOne",
            guards: String = "",
            repository: String? = nil
        ) async throws {
            let result = try await session.defineFeatureSet(
                name: name,
                activity: "\(eventType) Handler\(guards)",
                statements: [
                    "Extract the <m> from the <event: msg>.",
                    "Store the <m> into the <\(repository ?? self.repository)>.",
                    "Return an <OK: status> for the <handling>.",
                ]
            )
            guard case .featureSetDefined = result else {
                Issue.record("handler definition failed: \(result)")
                return
            }
        }

        func emit(_ payload: String) async throws {
            _ = try await session.executeStatement(
                "Emit a <\(eventType): event> with \(payload).")
        }

        /// What the handler wrote, read back through the session.
        func recordedPings() async throws -> [String] {
            _ = try? await session.executeStatement(
                "Retrieve the <pings> from the <\(repository)>.")
            let value = session.getVariable("pings")
            if let list = value as? [String] { return list }
            if let list = value as? [any Sendable] { return list.compactMap { $0 as? String } }
            if let single = value as? String { return [single] }
            return []
        }
    }

    @Test("Emit dispatches to a session-defined handler before the result returns")
    func emitFiresHandler() async throws {
        let playground = Playground()
        try await playground.defineRecorder()

        _ = try await playground.emit("{ msg: \"hello\" }")

        // No sleeps: executeStatement settles events before returning,
        // so the handler's Store is already visible.
        let pings = try await playground.recordedPings()
        #expect(pings == ["hello"])
    }

    @Test("State guards filter dispatch (ARO-0022)")
    func stateGuardsFilter() async throws {
        let playground = Playground()
        try await playground.defineRecorder(guards: "<status:ok>")

        try await playground.emit("{ msg: \"dropped\", status: \"bad\" }")
        try await playground.emit("{ msg: \"kept\", status: \"ok\" }")

        let pings = try await playground.recordedPings()
        #expect(pings == ["kept"])
    }

    @Test("Redefining a handler replaces its subscription instead of stacking")
    func redefinitionReplaces() async throws {
        let playground = Playground()
        try await playground.defineRecorder()
        // Same name, new registration — after this, one emit must
        // store one entry, not two.
        try await playground.defineRecorder()

        try await playground.emit("{ msg: \"once\" }")

        let pings = try await playground.recordedPings()
        #expect(pings == ["once"])
    }

    @Test("Two handlers for the same event both fire")
    func multipleHandlers() async throws {
        let playground = Playground()
        // Distinct repositories: two identical values stored into ONE
        // repository collapse to a single record, which would hide the
        // second dispatch this test exists to prove.
        let second = "pong\(playground.token)-repository"
        try await playground.defineRecorder(name: "RecorderOne")
        try await playground.defineRecorder(name: "RecorderTwo", repository: second)

        try await playground.emit("{ msg: \"fanout\" }")

        let pings = try await playground.recordedPings()
        #expect(pings == ["fanout"])
        _ = try? await playground.session.executeStatement(
            "Retrieve the <pongs> from the <\(second)>.")
        let pongs = playground.session.getVariable("pongs")
        #expect(pongs as? [String] == ["fanout"] || pongs as? String == "fanout")
    }

    @Test("clear() drops handler subscriptions")
    func clearDropsHandlers() async throws {
        let playground = Playground()
        try await playground.defineRecorder()
        playground.session.clear()

        try await playground.emit("{ msg: \"ghost\" }")

        // The handler is gone, so nothing was stored under this
        // test's private repository name.
        let pings = try await playground.recordedPings()
        #expect(pings.isEmpty)
    }

    @Test("A cascade — a handler that emits — settles before the result")
    func cascadeSettles() async throws {
        let playground = Playground()
        _ = try await playground.session.defineFeatureSet(
            name: "Relay",
            activity: "FirstHop\(playground.token.capitalized) Handler",
            statements: [
                "Extract the <m> from the <event: msg>.",
                "Emit a <\(playground.eventType): event> with { msg: <m> }.",
                "Return an <OK: status> for the <relay>.",
            ]
        )
        try await playground.defineRecorder()

        _ = try await playground.session.executeStatement(
            "Emit a <FirstHop\(playground.token.capitalized): event> with { msg: \"two-hops\" }.")

        let pings = try await playground.recordedPings()
        #expect(pings == ["two-hops"])
    }

    @Test("Service-bound handler activities are not subscribed")
    func serviceBoundHandlersExcluded() {
        #expect(REPLSession.domainHandlerEventType(for: "PingReceived Handler") == "PingReceived")
        #expect(REPLSession.domainHandlerEventType(for: "PingReceived Handler<status:ok>") == "PingReceived")
        #expect(REPLSession.domainHandlerEventType(for: "Socket Event Handler") == nil)
        #expect(REPLSession.domainHandlerEventType(for: "WebSocket Event Handler") == nil)
        #expect(REPLSession.domainHandlerEventType(for: "File Event Handler") == nil)
        #expect(REPLSession.domainHandlerEventType(for: "Navigate: KeyPress Handler") == nil)
        #expect(REPLSession.domainHandlerEventType(for: "Interactive") == nil)
    }
}

// ============================================================
// Repository observers in a session (GitLab #691 family)
// ============================================================
//
// A `{repository} Observer` was left unsubscribed in sessions, grouped with
// the families whose events come from a server the REPL never starts. Nothing
// wires an observer up but the bus, and its trigger is an ordinary statement —
// `Store`/`Update`/`Delete` publish `RepositoryChangedEvent` in-process — so a
// notebook could define one, see "Defined", and never hear from it again.
//
// The observable is a second repository the observer writes into, for the same
// reason the handler tests use one: it survives the statement that triggered
// it and can be read back without touching stdout capture.

@Suite("REPL repository observers", .serialized)
struct REPLRepositoryObserverTests {

    private struct Playground {
        let session = REPLSession()
        let token = "o" + String((UUID().uuidString + UUID().uuidString)
            .lowercased()
            .filter { $0.isLetter }
            .prefix(10))
        var watched: String { "stock\(token)-repository" }
        var log: String { "seen\(token)-repository" }

        func defineObserver(name: String = "WatchIt",
                            guards: String = "",
                            marker: String = "") async throws {
            let result = try await session.defineFeatureSet(
                name: name,
                activity: "\(watched) Observer\(guards)",
                statements: [
                    "Extract the <id> from the <event: entityId>.",
                    "Compute the <note> from \"\(marker)\" ++ <id>.",
                    "Store the <note> into the <\(log)>.",
                    "Return an <OK: status> for the <watching>.",
                ]
            )
            guard case .featureSetDefined = result else {
                Issue.record("observer definition failed: \(result)")
                return
            }
        }

        /// Each call binds a fresh name. Bindings are immutable for the life
        /// of the session, so reusing one would make the second store a rebind
        /// error rather than a second event — which is a property of the
        /// language, not something the observer under test should absorb.
        func store(_ literal: String, as name: String) async throws {
            _ = try await session.executeStatement(
                "Create the <\(name)> with \(literal).")
            _ = try await session.executeStatement(
                "Store the <\(name)> into the <\(watched)>.")
        }

        func seen() async throws -> [String] {
            _ = try? await session.executeStatement(
                "Retrieve the <notes> from the <\(log)>.")
            let value = session.getVariable("notes")
            if let list = value as? [String] { return list }
            if let list = value as? [any Sendable] { return list.compactMap { $0 as? String } }
            if let single = value as? String { return [single] }
            return []
        }
    }

    @Test("A Store reaches an observer defined in an earlier input")
    func storeReachesObserver() async throws {
        let p = Playground()
        try await p.defineObserver(marker: "saw:")

        try await p.store("{ id: \"sku-03\" }", as: "one")

        #expect(try await p.seen() == ["saw:sku-03"])
    }

    @Test("The observer sees the change type")
    func observerSeesChangeType() async throws {
        let p = Playground()
        let result = try await p.session.defineFeatureSet(
            name: "WatchKind",
            activity: "\(p.watched) Observer",
            statements: [
                "Extract the <kind> from the <event: changeType>.",
                "Store the <kind> into the <\(p.log)>.",
                "Return an <OK: status> for the <watching>.",
            ]
        )
        guard case .featureSetDefined = result else {
            Issue.record("definition failed: \(result)"); return
        }

        try await p.store("{ id: \"sku-04\" }", as: "one")

        #expect(try await p.seen() == ["created"])
    }

    @Test("State guards filter an observer the same way they filter a handler")
    func guardsFilterObservers() async throws {
        let p = Playground()
        try await p.defineObserver(guards: "<category:coffee>", marker: "kept:")

        try await p.store("{ id: \"tea-1\", category: \"tea\" }", as: "tea")
        try await p.store("{ id: \"cof-1\", category: \"coffee\" }", as: "cof")

        #expect(try await p.seen() == ["kept:cof-1"])
    }

    @Test("Redefining an observer replaces its subscription")
    func redefinitionReplaces() async throws {
        // Stacking a second subscription would run both bodies and record
        // the entity twice — the bug the handler path already guards against.
        let p = Playground()
        try await p.defineObserver(marker: "v1:")
        try await p.defineObserver(marker: "v2:")

        try await p.store("{ id: \"sku-05\" }", as: "one")

        #expect(try await p.seen() == ["v2:sku-05"])
    }

    @Test("An observer for another repository stays quiet")
    func otherRepositoryIgnored() async throws {
        let p = Playground()
        try await p.defineObserver(marker: "saw:")

        _ = try await p.session.executeStatement(
            "Create the <elsewhere> with { id: \"x-1\" }.")
        _ = try await p.session.executeStatement(
            "Store the <elsewhere> into the <unrelated\(p.token)-repository>.")

        #expect(try await p.seen().isEmpty)
    }
}
