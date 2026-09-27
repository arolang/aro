// ============================================================
// SessionLifecycle.swift
// ARO Runtime — connections come and go; partitions must too
// ARO-0094 §6.2, GitLab #885
// ============================================================
//
// Eviction is subscribed centrally rather than added to each server, because
// there are six places that publish a connect or a disconnect — the NIO socket
// server, its Windows counterpart, the WebSocket server, and the compiled
// binary's socket bridge — and a connection whose repositories are never
// dropped is a leak that only shows up after a week of uptime. One
// subscription covers every publisher, present and future, since they all go
// through the event bus.

import Foundation

public enum SessionLifecycle {

    /// Wire connection lifetime to partition lifetime. Called once at startup.
    public static func install(on eventBus: EventBus) {
        eventBus.subscribe(to: ClientConnectedEvent.self) { event in
            await SessionService.shared.connectionOpened(
                id: event.connectionId, transport: "socket", session: nil)
        }
        eventBus.subscribe(to: ClientDisconnectedEvent.self) { event in
            await SessionService.shared.connectionClosed(id: event.connectionId)
        }
        eventBus.subscribe(to: WebSocketConnectedEvent.self) { event in
            // Idempotent: the upgrade already registered this connection with
            // whatever session its cookie resolved to, and a nil session here
            // must not erase it.
            await SessionService.shared.connectionOpened(
                id: event.connectionId, transport: "websocket", session: nil)
        }
        eventBus.subscribe(to: WebSocketDisconnectedEvent.self) { event in
            await SessionService.shared.connectionClosed(id: event.connectionId)
        }
    }
}
