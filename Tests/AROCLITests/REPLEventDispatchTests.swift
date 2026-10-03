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

    /// Only a `{EventName} Handler` is a DOMAIN handler. The other families
    /// are not — several of them dispatch now, through their own
    /// subscriptions (see `REPLHandlerFamilyTests` below), but none of them
    /// is an `Emit` target, and reading one as a domain event named
    /// "File Event" is the bug `ActivityKind` exists to prevent.
    @Test("Only {EventName} Handler reads as a domain event")
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

// ============================================================
// Handler families: dispatched, or said out loud (GitLab #688)
// ============================================================
//
// A session used to accept every handler family with the same cheerful
// "Defined …" and deliver only two of them. These tests pin both halves of the
// fix: the families whose events an ARO statement can produce actually fire,
// and the families that need a transport the session does not own are named as
// undelivered rather than left silent.
//
// The classification tests are the cheap half and the important half: a
// diagnostic that lies in the other direction — telling a user that a family
// which *does* dispatch will not — would be a worse bug than the silence.

@Suite("REPL handler families")
struct REPLHandlerFamilyTests {

    @Test("Families an ARO statement can trigger are dispatched, and say what fires them")
    func dispatchedFamilies() {
        func trigger(_ activity: String) -> String? {
            guard case .dispatched(let trigger) = REPLSession.handlerFamily(for: activity) else {
                return nil
            }
            return trigger
        }

        #expect(trigger("UserCreated Handler") == "fires on <UserCreated: event>")
        #expect(trigger("UserCreated Handler<status:paid>") == "fires on <UserCreated: event>")
        #expect(trigger("user-repository Observer")?.contains("user-repository") == true)
        #expect(trigger("File Event Handler")?.contains("file-monitor") == true)
        #expect(trigger("StateTransition Handler<toState:paid>")?.contains("Accept") == true)
        #expect(trigger("status StateObserver<draft_to_paid>")?.contains("Accept") == true)
        #expect(trigger("NotificationSent Handler")?.contains("Notify") == true)
    }

    @Test("Transport-bound families are reported undelivered, with a reason and a way out")
    func undeliveredFamilies() {
        func reason(_ activity: String) -> String? {
            guard case .undelivered(let reason) = REPLSession.handlerFamily(for: activity) else {
                return nil
            }
            return reason
        }

        // WebSocket is classified before Socket, so the activity that
        // contains the other one must not be reported as the other one.
        #expect(reason("Socket Event Handler")?.contains("socket events") == true)
        #expect(reason("WebSocket Event Handler")?.contains("WebSocket events") == true)
        #expect(reason("KeyPress Handler<key:enter>")?.contains("KeyPress") == true)
        #expect(reason("cache-repository Evicted Handler")?.contains("cache-repository") == true)
        #expect(reason("Dashboard Watch: TasksUpdated Handler") != nil)
        #expect(reason("Application-End") != nil)

        // The advice a front-end prints always points somewhere.
        let advice = REPLSession.definitionAdvice(for: "Socket Event Handler")
        #expect(advice?.contains("aro run") == true)
    }

    @Test("An operationId or an Action is not a handler and gets no commentary")
    func nonHandlers() {
        #expect(REPLSession.handlerFamily(for: "listUsers") == .notAHandler)
        #expect(REPLSession.handlerFamily(for: "Interactive") == .notAHandler)
        #expect(REPLSession.handlerFamily(for: "Action takes <n>") == .notAHandler)
        #expect(REPLSession.definitionAdvice(for: "listUsers") == nil)
    }
}

// ============================================================
// File, state and notification dispatch in a session
// ============================================================

@Suite("REPL non-domain handler dispatch", .serialized)
struct REPLExtraHandlerDispatchTests {

    private struct Playground {
        let session = REPLSession()
        let token = "f" + String((UUID().uuidString + UUID().uuidString)
            .lowercased()
            .filter { $0.isLetter }
            .prefix(10))
        var log: String { "log\(token)-repository" }

        func define(name: String, activity: String, statements: [String]) async throws {
            let result = try await session.defineFeatureSet(
                name: name, activity: activity, statements: statements)
            guard case .featureSetDefined = result else {
                Issue.record("definition failed: \(result)")
                return
            }
        }

        /// What the handler wrote, read back through the session.
        func logged(as name: String) async throws -> [String] {
            _ = try? await session.executeStatement(
                "Retrieve the <\(name)> from the <\(log)>.")
            let value = session.getVariable(name)
            if let list = value as? [String] { return list }
            if let list = value as? [any Sendable] { return list.compactMap { $0 as? String } }
            if let single = value as? String { return [single] }
            return []
        }
    }

    @Test("A file change reaches a File Event Handler defined in an earlier input")
    func fileEventReachesHandler() async throws {
        // The event is published on the session's bus rather than produced by
        // a real watcher: what is under test is the subscription, and a test
        // that waited on FSEvents would be a test of the operating system's
        // latency. That `Start the <file-monitor>` publishes onto this bus at
        // all is the other half of the fix, and `init` registering
        // `FileMonitorService` is what makes it so.
        let p = Playground()
        try await p.define(name: "Handle Export Created", activity: "File Event Handler",
                           statements: [
                            "Extract the <dropped> from the <event: path>.",
                            "Store the <dropped> into the <\(p.log)>.",
                            "Return an <OK: status> for the <ingestion>.",
                           ])

        await p.session.eventBus.publishAndWait(FileCreatedEvent(path: "/drop/export.csv"))

        #expect(try await p.logged(as: "seen") == ["/drop/export.csv"])
    }

    @Test("The handler's name selects which changes reach it")
    func nameSelectsChange() async throws {
        let p = Playground()
        try await p.define(name: "Handle Export Deleted", activity: "File Event Handler",
                           statements: [
                            "Extract the <gone> from the <event: path>.",
                            "Store the <gone> into the <\(p.log)>.",
                            "Return an <OK: status> for the <ingestion>.",
                           ])

        // "Deleted" in the name means deletions only — the rule `aro run`
        // uses, so a notebook and an application route the same way.
        await p.session.eventBus.publishAndWait(FileCreatedEvent(path: "/drop/new.csv"))
        await p.session.eventBus.publishAndWait(FileDeletedEvent(path: "/drop/old.csv"))

        #expect(try await p.logged(as: "seen") == ["/drop/old.csv"])
    }

    @Test("A name that asks for no particular change gets all three")
    func unnamedGetsAllThree() async throws {
        let p = Playground()
        try await p.define(name: "Report Drop", activity: "File Event Handler",
                           statements: [
                            "Extract the <kind> from the <event: kind>.",
                            "Store the <kind> into the <\(p.log)>.",
                            "Return an <OK: status> for the <ingestion>.",
                           ])

        await p.session.eventBus.publishAndWait(FileCreatedEvent(path: "/drop/a.csv"))
        await p.session.eventBus.publishAndWait(FileModifiedEvent(path: "/drop/a.csv"))
        await p.session.eventBus.publishAndWait(FileDeletedEvent(path: "/drop/a.csv"))

        let kinds = Set(try await p.logged(as: "kinds"))
        #expect(kinds == ["created", "modified", "deleted"])
    }

    @Test("clear() drops a file handler's subscriptions too")
    func clearDropsFileHandler() async throws {
        let p = Playground()
        try await p.define(name: "Report Drop", activity: "File Event Handler",
                           statements: [
                            "Extract the <dropped> from the <event: path>.",
                            "Store the <dropped> into the <\(p.log)>.",
                            "Return an <OK: status> for the <ingestion>.",
                           ])
        p.session.clear()

        await p.session.eventBus.publishAndWait(FileCreatedEvent(path: "/drop/ghost.csv"))

        #expect(try await p.logged(as: "seen").isEmpty)
    }

    @Test("An Accept reaches a StateTransition Handler, guard and all")
    func acceptReachesStateHandler() async throws {
        let p = Playground()
        try await p.define(name: "Document Submitted",
                           activity: "StateTransition Handler<toState:submitted>",
                           statements: [
                            "Extract the <entity-id> from the <event: entityId>.",
                            "Extract the <was> from the <event: fromState>.",
                            "Compute the <note> from <entity-id> ++ \":\" ++ <was>.",
                            "Store the <note> into the <\(p.log)>.",
                            "Return an <OK: status> for the <notification>.",
                           ])

        _ = try await p.session.executeStatement(
            "Create the <document> with { id: \"DOC-1\", status: \"draft\" }.")
        _ = try await p.session.executeStatement(
            "Accept the <transition: draft_to_submitted> on <document: status>.")

        #expect(try await p.logged(as: "notes") == ["DOC-1:draft"])
    }

    @Test("A guard that does not match keeps the state handler quiet")
    func stateGuardFilters() async throws {
        let p = Playground()
        try await p.define(name: "Document Approved",
                           activity: "StateTransition Handler<toState:approved>",
                           statements: [
                            "Extract the <entity-id> from the <event: entityId>.",
                            "Store the <entity-id> into the <\(p.log)>.",
                            "Return an <OK: status> for the <notification>.",
                           ])

        _ = try await p.session.executeStatement(
            "Create the <document> with { id: \"DOC-2\", status: \"draft\" }.")
        _ = try await p.session.executeStatement(
            "Accept the <transition: draft_to_submitted> on <document: status>.")

        #expect(try await p.logged(as: "ids").isEmpty)
    }

    @Test("The legacy StateObserver spelling binds `transition`, not `event`")
    func stateObserverBindsTransition() async throws {
        let p = Playground()
        try await p.define(name: "Audit Status", activity: "status StateObserver",
                           statements: [
                            "Extract the <new-state> from the <transition: toState>.",
                            "Store the <new-state> into the <\(p.log)>.",
                            "Return an <OK: status> for the <audit>.",
                           ])

        _ = try await p.session.executeStatement(
            "Create the <document> with { id: \"DOC-3\", status: \"draft\" }.")
        _ = try await p.session.executeStatement(
            "Accept the <transition: draft_to_submitted> on <document: status>.")

        #expect(try await p.logged(as: "states") == ["submitted"])
    }

    @Test("A Notify reaches a NotificationSent Handler")
    func notifyReachesHandler() async throws {
        let p = Playground()
        try await p.define(name: "Welcome Them", activity: "NotificationSent Handler",
                           statements: [
                            "Extract the <who> from the <event: user>.",
                            "Store the <who> into the <\(p.log)>.",
                            "Return an <OK: status> for the <welcome>.",
                           ])

        _ = try await p.session.executeStatement(
            "Create the <recipient> with \"ada@example.com\".")
        _ = try await p.session.executeStatement(
            "Notify the <recipient> with \"Your document is in review\".")

        #expect(try await p.logged(as: "recipients") == ["ada@example.com"])
    }
}
