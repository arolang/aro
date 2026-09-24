// ============================================================
// SocketServerEventTests.swift
// ARO Runtime — the compiled socket server announces what the client announces
// GitLab #881
// ============================================================
//
// `aro_native_socket_server_start` used to wire its three callbacks to `print`
// statements that *imitated* what a handler would have logged, and to broadcast
// every datagram it received. No `DomainEvent` was published, so the
// `socket.connected` / `socket.data` / `socket.disconnected` handlers that
// `LLVMCodeGenerator` faithfully registers were never called — a compiled
// server looked like it worked while every line of the program's own socket
// logic was dead.
//
// A compiled socket *client* worked, because `AROSocketClient` co-publishes all
// three. That asymmetry is what these tests pin: the payload a handler reads
// must not depend on which end of the socket it is on, nor on whether the
// program was interpreted or compiled. A handler says `<connection: id>`,
// `<packet: message>` and `<event: connectionId>`, and those names are the
// contract — hence the assertions on exact keys rather than on "an event was
// published".

import Foundation
import Testing
@testable import ARORuntime

#if !os(Windows)

@Suite("Compiled socket server events (#881)", .serialized)
struct SocketServerEventTests {

    /// Publish via `body`, then wait for the event this test is looking for.
    ///
    /// `EventBus.publish` is fire-and-forget — it hands off to a `Task` — and
    /// `EventBus.shared` is shared with every other suite running in parallel.
    /// A fixed sleep is therefore both flaky and slow: the first test in a cold
    /// suite loses the race with its own subscription, and the rest wait for
    /// nothing. Poll for the event that mentions this test's own connection id
    /// instead, and stop as soon as it lands.
    private func awaitPayload(_ type: String,
                              mentioning id: String,
                              during body: () -> Void) async -> [String: any Sendable]? {
        let box = EventBox()
        EventBus.shared.subscribe(to: DomainEvent.self) { event in
            box.append(event)
        }
        // Let the subscription register before anything is published.
        try? await Task.sleep(nanoseconds: 50_000_000)
        body()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let match = box.drain()
                .filter({ $0.domainEventType == type })
                .first(where: { String(describing: $0.payload).contains(id) }) {
                return match.payload
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DomainEvent] = []
        func append(_ e: DomainEvent) { lock.lock(); events.append(e); lock.unlock() }
        func drain() -> [DomainEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    @Test("A connection publishes socket.connected with the connection's id and address")
    func connectPublishesConnection() async {
        let payload = await awaitPayload("socket.connected", mentioning: "conn-1") {
            reportSocketConnect(connectionId: "conn-1", remoteAddress: "127.0.0.1:51000")
        }
        let connection = payload?["connection"] as? [String: any Sendable]
        #expect(connection?["id"] as? String == "conn-1")
        #expect(connection?["remoteAddress"] as? String == "127.0.0.1:51000")
    }

    @Test("Received bytes publish socket.data under every name a handler may read")
    func dataPublishesEveryAlias() async {
        let payload = await awaitPayload("socket.data", mentioning: "conn-2") {
            reportSocketData(connectionId: "conn-2", data: Data("ping\n".utf8))
        }
        let packet = payload?["packet"] as? [String: any Sendable]
        // `message`, `buffer` and `data` are three spellings of the same bytes;
        // the examples use all three, so dropping one silently breaks a program.
        #expect(packet?["message"] as? String == "ping\n")
        #expect(packet?["buffer"] as? String == "ping\n")
        #expect(packet?["data"] as? String == "ping\n")
        #expect(packet?["connection"] as? String == "conn-2")
    }

    @Test("A disconnect publishes socket.disconnected keyed the way the client keys it")
    func disconnectPublishesEvent() async {
        let payload = await awaitPayload("socket.disconnected", mentioning: "conn-3") {
            reportSocketDisconnect(connectionId: "conn-3")
        }
        let event = payload?["event"] as? [String: any Sendable]
        #expect(event?["connectionId"] as? String == "conn-3")
        #expect(event?["reason"] as? String != nil)
    }

    @Test("The typed event travels beside the domain event, as the file watcher does")
    func typedEventsAreCoPublished() async {
        let box = TypedBox()
        EventBus.shared.subscribe(to: ClientConnectedEvent.self) { e in box.record(e.connectionId) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        reportSocketConnect(connectionId: "conn-4", remoteAddress: "127.0.0.1:51001")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !box.seen().contains("conn-4") {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(box.seen().contains("conn-4"))
    }

    private final class TypedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        func record(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        func seen() -> [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }

    // MARK: - What the payload shape costs the dispatcher

    @Test("Overriding a bound name needs allowRebind — the dispatcher's one lever")
    func overridingABoundNameRequiresAllowRebind() {
        // `socket.disconnected` is the one payload whose own key is `event`, so
        // the compiled dispatcher — which binds `event` to the whole payload and
        // then binds each payload key by name — lands on a name it has already
        // taken. It is meant to override; without `allowRebind` the immutability
        // backstop refuses, and the handler died with "Cannot rebind immutable
        // variable 'event'" after reading `<event: connectionId>` off the outer
        // payload, which has no such key.
        //
        // This pins the primitive the fix leans on, not the call site. The call
        // site itself is covered end to end by `Examples/MultiService`, whose
        // disconnect handler now runs in compiled mode (`mode: both`).
        let context = RuntimeContext(featureSetName: "socket.disconnected Handler")
        let inner: [String: any Sendable] = ["connectionId": "conn-5", "reason": "connection closed"]

        context.bind("event", value: ["event": inner] as [String: any Sendable])
        context.bind("event", value: inner, allowRebind: true)

        let bound: [String: any Sendable]? = context.resolve("event")
        #expect(bound?["connectionId"] as? String == "conn-5",
                "the payload's own key must win, or <event: connectionId> reads the wrapper")
    }
}

#endif
