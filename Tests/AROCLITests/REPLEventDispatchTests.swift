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
        let session = REPLSession(suppressLogPrefix: true)
        let token = String(UUID().uuidString.prefix(8).lowercased()
            .filter { $0.isLetter })
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
