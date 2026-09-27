// ============================================================
// SessionServiceTests.swift
// ARO Runtime — the cookie has to actually mean something
// ARO-0094 §8, GitLab #885
// ============================================================
//
// The property under test throughout: a cookie is only a session if the
// runtime minted it, has not forgotten it, and it has not expired. Every other
// cookie — absent, malformed, forged, stale, logged out — resolves to nothing,
// and nothing is what makes a session-scoped repository fail rather than read
// somebody else's rows.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Sessions (ARO-0094 §8)", .serialized)
struct SessionServiceTests {

    private func service() -> SessionService {
        SessionService(storage: InMemoryRepositoryStorage())
    }

    private func insecurePolicy() -> SessionPolicy {
        // Minting refuses plain HTTP by default (§8.2); these tests are not
        // about transport, so they say so explicitly rather than pretending.
        var policy = SessionPolicy()
        policy.requiresSecureTransport = false
        return policy
    }

    // MARK: - Minting and validating

    @Test("A minted cookie resolves back to its session")
    func roundTrip() async throws {
        let service = service()
        await service.configure(insecurePolicy())
        let minted = try await service.mint(fields: ["user": "alice"], overSecureTransport: false)

        // The store behind mint is a detached Task; let it land.
        try await Task.sleep(nanoseconds: 50_000_000)

        let resolved = await service.resolve(cookieValue: minted.cookieValue)
        #expect(try resolved.get() == minted.id)
    }

    @Test("The cookie carries an id and nothing else")
    func cookieIsOpaque() async throws {
        // §8.2. State stays server-side, which is what keeps logout meaningful:
        // a framework that puts the session *in* the cookie cannot revoke it.
        let service = service()
        await service.configure(insecurePolicy())
        let minted = try await service.mint(fields: ["user": "alice", "role": "admin"],
                                            overSecureTransport: false)
        #expect(!minted.cookieValue.contains("alice"))
        #expect(!minted.cookieValue.contains("admin"))
    }

    @Test("An id of at least 128 bits, from the system CSPRNG")
    func identifiersAreLongAndUnique() {
        let ids = (0..<200).map { _ in SessionService.freshIdentifier() }
        #expect(Set(ids).count == 200)
        // 32 bytes, base64url without padding.
        #expect(ids.allSatisfy { $0.count >= 22 })
    }

    @Test("A tampered cookie does not verify")
    func forgedSignatureRejected() async throws {
        let service = service()
        await service.configure(insecurePolicy())
        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Keep the signature, change the id — the shape of an attacker who
        // knows another session's id and has a valid cookie of their own.
        let parts = minted.cookieValue.split(separator: ".", maxSplits: 1)
        let forged = "\(SessionService.freshIdentifier()).\(parts[1])"
        #expect(await service.resolve(cookieValue: forged) == .failure(.badSignature))
    }

    @Test("Absent and malformed cookies resolve to nothing, not to something")
    func absentAndMalformed() async {
        let service = service()
        await service.configure(insecurePolicy())
        #expect(await service.resolve(cookieHeader: "") == .failure(.noCookie))
        #expect(await service.resolve(cookieHeader: "other=1") == .failure(.noCookie))
        #expect(await service.resolve(cookieValue: "no-dot-here") == .failure(.malformed))
        #expect(await service.resolve(cookieValue: ".") == .failure(.malformed))
    }

    @Test("A revoked session stops resolving, and its repositories go with it")
    func revocationIsImmediate() async throws {
        // This is the property a cookie-backed session store cannot offer.
        let storage = InMemoryRepositoryStorage()
        let service = SessionService(storage: storage)
        await service.configure(insecurePolicy())
        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await storage.store(value: ["id": "1", "item": "hat"] as [String: any Sendable],
                            in: "cart-repository", businessActivity: "Shop",
                            caller: "session:\(minted.id)")

        await service.revoke(sessionId: minted.id)

        #expect(await service.resolve(cookieValue: minted.cookieValue) == .failure(.unknown))
        #expect(await storage.retrieve(from: "cart-repository", businessActivity: "Shop",
                                       caller: "session:\(minted.id)").isEmpty)
    }

    @Test("An idle session expires, and expiring revokes it")
    func idleExpiry() async throws {
        let storage = InMemoryRepositoryStorage()
        let service = SessionService(storage: storage)
        var policy = insecurePolicy()
        policy.idleTimeout = 1
        await service.configure(policy)

        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Age `last-seen` rather than waiting: the clock is the thing under
        // test, not the test's patience.
        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session", caller: "",
                                          where: "id", equals: minted.id)
        var row = try #require(rows.first as? [String: any Sendable])
        row["last-seen"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        await storage.store(value: row, in: SessionRepositories.sessions,
                            businessActivity: "session", caller: "")

        #expect(await service.resolve(cookieValue: minted.cookieValue) == .failure(.idleExpired))
        // And it is gone, not merely refused — a session that keeps being
        // refused but keeps existing is a row that never leaves the repository.
        #expect(await storage.retrieve(from: SessionRepositories.sessions,
                                       businessActivity: "session", caller: "",
                                       where: "id", equals: minted.id).isEmpty)
    }

    @Test("A busy session still reaches its absolute expiry")
    func absoluteExpiry() async throws {
        // The one an attacker holding a stolen id cannot refresh away.
        let storage = InMemoryRepositoryStorage()
        let service = SessionService(storage: storage)
        var policy = insecurePolicy()
        policy.absoluteTimeout = 1
        await service.configure(policy)

        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session", caller: "",
                                          where: "id", equals: minted.id)
        var row = try #require(rows.first as? [String: any Sendable])
        row["created"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
        row["last-seen"] = ISO8601DateFormatter().string(from: Date())   // busy right now
        await storage.store(value: row, in: SessionRepositories.sessions,
                            businessActivity: "session", caller: "")

        #expect(await service.resolve(cookieValue: minted.cookieValue) == .failure(.absoluteExpired))
    }

    @Test("Refusing to mint over plain HTTP")
    func insecureTransportRefused() async {
        let service = service()
        await service.configure(SessionPolicy())   // secure required, the default
        await #expect(throws: SessionError.insecureTransport) {
            _ = try await service.mint(overSecureTransport: false)
        }
    }

    // MARK: - Rotation

    @Test("Rotation changes the id and keeps the session")
    func rotationPreservesTheRecord() async throws {
        let storage = InMemoryRepositoryStorage()
        let service = SessionService(storage: storage)
        await service.configure(insecurePolicy())
        let minted = try await service.mint(fields: ["user": "alice"], overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        let rotated = try #require(await service.rotate(sessionId: minted.id))
        #expect(rotated != minted.cookieValue)
        #expect(await service.resolve(cookieValue: minted.cookieValue) == .failure(.unknown),
                "the fixated id must stop working — that is the whole defence")

        let newId = try await service.resolve(cookieValue: rotated).get()
        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session", caller: "",
                                          where: "id", equals: newId)
        #expect((rows.first as? [String: any Sendable])?["user"] as? String == "alice")
    }

    // MARK: - Connections

    @Test("A connection is a connection until it is attached")
    func promotion() async throws {
        let service = service()
        await service.configure(insecurePolicy())
        await service.connectionOpened(id: "c1", transport: "socket", session: nil)
        #expect(await service.caller(forConnection: "c1") == .connection(id: "c1"))

        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        try await service.attach(sessionId: minted.id, toConnection: "c1")
        #expect(await service.caller(forConnection: "c1") == .session(id: minted.id, connection: "c1"))
    }

    @Test("Attaching a session that does not exist is an error")
    func attachRequiresARealSession() async {
        let service = service()
        await service.connectionOpened(id: "c1", transport: "socket", session: nil)
        await #expect(throws: SessionError.noSuchSession("made-up")) {
            try await service.attach(sessionId: "made-up", toConnection: "c1")
        }
    }

    @Test("A connection cannot change session")
    func promotionIsIrreversible() async throws {
        // §6.1: the reverse is a downgrade attack written in one statement.
        let service = service()
        await service.configure(insecurePolicy())
        let first = try await service.mint(overSecureTransport: false)
        let second = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await service.connectionOpened(id: "c1", transport: "socket", session: nil)
        try await service.attach(sessionId: first.id, toConnection: "c1")
        await #expect(throws: (any Error).self) {
            try await service.attach(sessionId: second.id, toConnection: "c1")
        }
        #expect(await service.caller(forConnection: "c1") == .session(id: first.id, connection: "c1"))
    }

    @Test("Closing a connection drops its repositories but not its session")
    func disconnectEviction() async throws {
        // §6.2. An HTTP client reconnects constantly and a dropped WebSocket
        // should not log anyone out, so the session outlives the connection.
        let storage = InMemoryRepositoryStorage()
        let service = SessionService(storage: storage)
        await service.configure(insecurePolicy())
        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await service.connectionOpened(id: "c1", transport: "websocket", session: minted.id)
        await storage.store(value: ["id": "1"] as [String: any Sendable],
                            in: "partial-repository", businessActivity: "Shop", caller: "conn:c1")

        await service.connectionClosed(id: "c1")

        #expect(await storage.retrieve(from: "partial-repository", businessActivity: "Shop",
                                       caller: "conn:c1").isEmpty)
        #expect(await service.resolve(cookieValue: minted.cookieValue).isSuccess)
        #expect(await service.caller(forConnection: "c1") == .connection(id: "c1"))
    }

    @Test("Revoking a session names the connections holding it")
    func revocationReachesConnections() async throws {
        // Otherwise a logged-out user with an open WebSocket stays connected
        // and authenticated until the socket happens to close.
        let service = service()
        await service.configure(insecurePolicy())
        let minted = try await service.mint(overSecureTransport: false)
        try await Task.sleep(nanoseconds: 50_000_000)

        await service.connectionOpened(id: "c1", transport: "websocket", session: minted.id)
        await service.connectionOpened(id: "c2", transport: "websocket", session: minted.id)
        let toClose = await service.revoke(sessionId: minted.id)
        #expect(Set(toClose) == ["c1", "c2"])
    }

    // MARK: - The cookie header and Origin

    @Test("The Set-Cookie carries every attribute §8.2 asks for")
    func cookieAttributes() async {
        let service = service()
        await service.configure(SessionPolicy())
        let header = await service.setCookieHeader(for: "abc.def")
        #expect(header.contains("aro_session=abc.def"))
        #expect(header.contains("HttpOnly"))
        #expect(header.contains("Secure"))
        #expect(header.contains("SameSite=Lax"))
        #expect(header.contains("Path=/"))
    }

    @Test("An unconfigured origin list accepts nothing")
    func originDefaultsToRefusal() async {
        // The safe default for an unanswered security question is no. A
        // cookie-authenticated WebSocket with no origin list is open to
        // cross-site hijacking, and SameSite does not cover the handshake.
        let service = service()
        await service.configure(insecurePolicy())
        #expect(!(await service.isAcceptableOrigin("https://shop.example")))
        #expect(!(await service.isAcceptableOrigin(nil)))

        var policy = insecurePolicy()
        policy.allowedOrigins = ["https://shop.example"]
        await service.configure(policy)
        #expect(await service.isAcceptableOrigin("https://shop.example"))
        #expect(!(await service.isAcceptableOrigin("https://evil.example")))
        #expect(!(await service.isAcceptableOrigin(nil)))
    }

    @Test("Cookie headers parse by name, not by substring")
    func cookieParsing() {
        let cookies = SessionService.parseCookies("a=1; not_aro_session=x; aro_session=real; b=2")
        #expect(cookies["aro_session"] == "real")
        #expect(cookies["not_aro_session"] == "x")
        #expect(cookies["a"] == "1")
    }
}

private extension Result where Success == String, Failure == SessionRejection {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
