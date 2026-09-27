// ============================================================
// SessionService.swift
// ARO Runtime — minting, validating and expiring sessions
// ARO-0094 §8, GitLab #885
// ============================================================
//
// What the runtime owns, because it all happens before any feature set runs:
// minting ids, validating the cookie, refreshing `last-seen`, evicting on
// expiry, and refusing a request whose cookie does not match. What the
// *program* owns is everything after that — the sessions repository is an
// ordinary application-scoped repository, so logout is a `Delete` statement
// and auditing is an observer feature set.
//
// The cookie carries an opaque id and nothing else. That is the whole design
// decision behind revocation working: a framework that puts state in the
// cookie cannot invalidate it, which Django's own documentation says of its
// cookie backend and which Rails inherits by encrypting rather than
// dereferencing. An id costs one repository read and buys `Delete`.
//
// It is signed, not encrypted. There is nothing secret in an opaque handle;
// what is wanted is tamper-evidence, so a forged id is rejected before it
// reaches storage rather than becoming a lookup miss that leaks timing.

import Foundation
import Crypto

/// How sessions behave for this application.
public struct SessionPolicy: Sendable {

    /// The cookie's name. Taken from the contract's `securitySchemes` entry
    /// when one declares `type: apiKey, in: cookie`; this is the fallback.
    public var cookieName: String

    /// Idle expiry — a session untouched for this long is gone.
    public var idleTimeout: TimeInterval

    /// Absolute expiry — a session lives no longer than this however busy it is.
    /// The one an attacker with a stolen id cannot refresh indefinitely.
    public var absoluteTimeout: TimeInterval

    /// `SameSite`. `Lax` by default; `Strict` for applications that never
    /// accept a top-level cross-site navigation into an authenticated page.
    public var sameSite: String

    /// Whether the transport is TLS. A session cookie is not issued over plain
    /// HTTP at all (§8.2) — the `Secure` attribute tells the browser what to
    /// do, and does nothing about having handed the session to a MITM already.
    public var requiresSecureTransport: Bool

    /// Origins a WebSocket upgrade may carry. Empty means none was configured,
    /// which is refused for a cookie-authenticated socket.
    public var allowedOrigins: [String]

    public init(cookieName: String = "aro_session",
                idleTimeout: TimeInterval = 30 * 60,
                absoluteTimeout: TimeInterval = 12 * 60 * 60,
                sameSite: String = "Lax",
                requiresSecureTransport: Bool = true,
                allowedOrigins: [String] = []) {
        self.cookieName = cookieName
        self.idleTimeout = idleTimeout
        self.absoluteTimeout = absoluteTimeout
        self.sameSite = sameSite
        self.requiresSecureTransport = requiresSecureTransport
        self.allowedOrigins = allowedOrigins
    }
}

/// Why a presented cookie did not produce a session.
public enum SessionRejection: Error, Sendable, Equatable, CustomStringConvertible {
    case noCookie
    case malformed
    case badSignature
    case unknown          // well-formed, correctly signed, but not in the repository
    case idleExpired
    case absoluteExpired

    public var description: String {
        switch self {
        case .noCookie:         return "no session cookie"
        case .malformed:        return "the session cookie is malformed"
        case .badSignature:     return "the session cookie's signature does not verify"
        case .unknown:          return "the session is not in the sessions repository"
        case .idleExpired:      return "the session expired through inactivity"
        case .absoluteExpired:  return "the session reached its absolute expiry"
        }
    }
}

/// The repositories the runtime maintains on the program's behalf (§9).
public enum SessionRepositories {
    public static let sessions    = "sessions-repository"
    public static let connections = "connections-repository"
}

/// Mints and validates sessions, and keeps the sessions repository in step.
public actor SessionService {

    public static let shared = SessionService()

    private var policy = SessionPolicy()
    private let storage: any RepositoryStorageService

    /// The signing key. Per-process and never written down, so restarting the
    /// server invalidates outstanding cookies — which is the safe default for
    /// an in-memory sessions repository, whose rows did not survive either.
    /// `ARO_SESSION_KEY` supplies a stable one for a `.store`-backed
    /// deployment or a multi-instance one.
    private let signingKey: SymmetricKey

    /// connection id → session id, for WebSocket frames and promoted sockets.
    /// A frame is attributed from here rather than from a cookie it does not
    /// carry (§4.2).
    private var sessionByConnection: [String: String] = [:]

    /// session id → the connections currently holding it, so revoking a
    /// session can close them (§6.2). Without this a logged-out user with an
    /// open WebSocket stays connected and authenticated.
    private var connectionsBySession: [String: Set<String>] = [:]

    public init(storage: (any RepositoryStorageService)? = nil) {
        self.storage = storage ?? RuntimeContainer.default.repositoryStorage
        if let configured = ProcessInfo.processInfo.environment["ARO_SESSION_KEY"],
           let data = Data(base64Encoded: configured) ?? configured.data(using: .utf8) {
            self.signingKey = SymmetricKey(data: data)
        } else {
            self.signingKey = SymmetricKey(size: .bits256)
        }
    }

    // MARK: - Configuration

    public func configure(_ policy: SessionPolicy) {
        self.policy = policy
        SessionPolicyStore.shared.policy = policy
    }
    public func currentPolicy() -> SessionPolicy { policy }

    // MARK: - Minting

    /// Create a session and record it. The value returned is what goes in the
    /// cookie: the id, a dot, and the signature over it.
    ///
    /// `fields` is whatever the application wants on the record — `user`,
    /// `roles`, anything. The runtime adds `id`, `created` and `last-seen` and
    /// otherwise does not interpret it.
    public func mint(fields: [String: any Sendable] = [:],
                     overSecureTransport: Bool) throws -> (id: String, cookieValue: String) {
        guard overSecureTransport || !policy.requiresSecureTransport else {
            throw SessionError.insecureTransport
        }
        let id = Self.freshIdentifier()
        let now = Date()
        var record = fields
        record["id"] = id
        record["created"] = ISO8601DateFormatter().string(from: now)
        record["last-seen"] = ISO8601DateFormatter().string(from: now)
        let captured = record
        Task { [storage] in
            // The sessions repository is application-scoped by definition — it
            // is the thing sessions are looked up in, so it cannot itself be
            // per-session.
            await storage.store(value: captured,
                                in: SessionRepositories.sessions,
                                businessActivity: "session",
                                caller: "")
        }
        return (id, sign(id))
    }

    /// 256 bits from the system CSPRNG, URL-safe. §8.2 asks for at least 128.
    static func freshIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Signing

    private func sign(_ id: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: signingKey)
        let signature = Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(id).\(signature)"
    }

    /// The id inside a cookie value, if the signature verifies.
    ///
    /// Verified with `HMAC.isValidAuthenticationCode`, which compares in
    /// constant time — a byte-by-byte `==` on a MAC is a timing oracle for
    /// forging one.
    func unsign(_ cookieValue: String) -> Result<String, SessionRejection> {
        let parts = cookieValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return .failure(.malformed)
        }
        let id = String(parts[0])
        var padded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let presented = Data(base64Encoded: padded) else { return .failure(.malformed) }
        guard HMAC<SHA256>.isValidAuthenticationCode(presented,
                                                     authenticating: Data(id.utf8),
                                                     using: signingKey) else {
            return .failure(.badSignature)
        }
        return .success(id)
    }

    // MARK: - Validation

    /// Resolve a cookie header to a caller.
    ///
    /// Every step can only narrow: a cookie that is absent, malformed, forged,
    /// unknown or expired yields no session, never a different one. On success
    /// `last-seen` is refreshed, which is what lets an open WebSocket hold its
    /// session (§6.3).
    public func resolve(cookieHeader: String) async -> Result<String, SessionRejection> {
        let cookies = Self.parseCookies(cookieHeader)
        guard let value = cookies[policy.cookieName] else { return .failure(.noCookie) }
        return await resolve(cookieValue: value)
    }

    public func resolve(cookieValue: String) async -> Result<String, SessionRejection> {
        let id: String
        switch unsign(cookieValue) {
        case .success(let verified): id = verified
        case .failure(let why):      return .failure(why)
        }

        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session",
                                          caller: "",
                                          where: "id", equals: id)
        guard let row = rows.compactMap({ $0 as? [String: any Sendable] }).first else {
            // Correctly signed but not in the repository: this is what logout
            // looks like from the outside, and what a restart looks like.
            return .failure(.unknown)
        }

        let now = Date()
        let parser = ISO8601DateFormatter()
        if let createdText = row["created"] as? String,
           let created = parser.date(from: createdText),
           now.timeIntervalSince(created) > policy.absoluteTimeout {
            await revoke(sessionId: id)
            return .failure(.absoluteExpired)
        }
        if let seenText = row["last-seen"] as? String,
           let seen = parser.date(from: seenText),
           now.timeIntervalSince(seen) > policy.idleTimeout {
            await revoke(sessionId: id)
            return .failure(.idleExpired)
        }

        var refreshed = row
        refreshed["last-seen"] = parser.string(from: now)
        await storage.store(value: refreshed,
                            in: SessionRepositories.sessions,
                            businessActivity: "session",
                            caller: "")
        return .success(id)
    }

    // MARK: - Rotation

    /// Give an existing session a new id, keeping its record (§8.2).
    ///
    /// The session-fixation defence: an id an attacker planted before the
    /// privilege change is not the id that has the privilege after it.
    public func rotate(sessionId: String) async -> String? {
        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session",
                                          caller: "",
                                          where: "id", equals: sessionId)
        guard var row = rows.compactMap({ $0 as? [String: any Sendable] }).first else { return nil }

        let newId = Self.freshIdentifier()
        row["id"] = newId
        row["last-seen"] = ISO8601DateFormatter().string(from: Date())

        // The data moves with the identity. A rotation that left the cart
        // behind would read as "logging in emptied my basket".
        _ = await storage.dropPartition(caller: "session:\(sessionId)")
        await storage.store(value: row, in: SessionRepositories.sessions,
                            businessActivity: "session", caller: "")
        _ = await storage.delete(from: SessionRepositories.sessions,
                                 businessActivity: "session", caller: "",
                                 where: "id", equals: sessionId)

        if let held = connectionsBySession.removeValue(forKey: sessionId) {
            for connection in held { sessionByConnection[connection] = newId }
            connectionsBySession[newId] = held
        }
        return sign(newId)
    }

    // MARK: - Revocation and eviction (§6.2)

    /// Forget a session: its row, its repositories, and the connections that
    /// were holding it.
    ///
    /// Returns those connection ids so the caller can close them — a revoked
    /// user with an open socket is still connected until somebody does.
    @discardableResult
    public func revoke(sessionId: String) async -> [String] {
        _ = await storage.delete(from: SessionRepositories.sessions,
                                 businessActivity: "session", caller: "",
                                 where: "id", equals: sessionId)
        _ = await storage.dropPartition(caller: "session:\(sessionId)")

        let held = connectionsBySession.removeValue(forKey: sessionId) ?? []
        for connection in held { sessionByConnection[connection] = nil }
        return Array(held)
    }

    // MARK: - Connections

    /// Record a live connection (§9.1).
    /// Idempotent, and deliberately so: a WebSocket is registered at upgrade —
    /// the only moment its cookie is readable — and again when the channel
    /// handler adds the connection. The second call must not erase the session
    /// the first one resolved, so a nil session never overwrites a known one.
    public func connectionOpened(id: String, transport: String, session: String?) async {
        if let session {
            sessionByConnection[id] = session
            connectionsBySession[session, default: []].insert(id)
        } else if sessionByConnection[id] != nil {
            return
        }
        await storage.store(value: [
            "id": id,
            "transport": transport,
            "session": session ?? "",
            "connected": ISO8601DateFormatter().string(from: Date())
        ] as [String: any Sendable],
        in: SessionRepositories.connections, businessActivity: "session", caller: "")
    }

    /// A connection closed: drop its connection-scoped repositories and its row.
    ///
    /// The session survives — an HTTP client reconnects constantly and a
    /// dropped WebSocket should not log anyone out.
    public func connectionClosed(id: String) async {
        if let session = sessionByConnection.removeValue(forKey: id) {
            connectionsBySession[session]?.remove(id)
            if connectionsBySession[session]?.isEmpty == true {
                connectionsBySession[session] = nil
            }
        }
        _ = await storage.dropPartition(caller: "conn:\(id)")
        _ = await storage.delete(from: SessionRepositories.connections,
                                 businessActivity: "session", caller: "",
                                 where: "id", equals: id)
    }

    /// Promote a connection to a session (§6.1, the `Attach` action).
    ///
    /// Irreversible within the connection: a connection that has been a
    /// session cannot become anonymous again, because the reverse is a
    /// downgrade attack written in one statement. Closing the socket is how a
    /// peer stops being that session.
    public func attach(sessionId: String, toConnection connectionId: String) async throws {
        if let existing = sessionByConnection[connectionId], existing != sessionId {
            throw SessionError.alreadyAttached(connection: connectionId, session: existing)
        }
        let rows = await storage.retrieve(from: SessionRepositories.sessions,
                                          businessActivity: "session",
                                          caller: "",
                                          where: "id", equals: sessionId)
        guard !rows.isEmpty else { throw SessionError.noSuchSession(sessionId) }

        sessionByConnection[connectionId] = sessionId
        connectionsBySession[sessionId, default: []].insert(connectionId)

        let live = await storage.retrieve(from: SessionRepositories.connections,
                                          businessActivity: "session", caller: "",
                                          where: "id", equals: connectionId)
        if var row = live.compactMap({ $0 as? [String: any Sendable] }).first {
            row["session"] = sessionId
            await storage.store(value: row, in: SessionRepositories.connections,
                                businessActivity: "session", caller: "")
        }
    }

    /// The caller a connection's events run as.
    public func caller(forConnection id: String) -> CallerIdentity {
        if let session = sessionByConnection[id] {
            return .session(id: session, connection: id)
        }
        return .connection(id: id)
    }

    /// Test seam — a process has one application, and these tests share it.
    public func resetForTesting() {
        sessionByConnection.removeAll()
        connectionsBySession.removeAll()
        policy = SessionPolicy()
    }

    // MARK: - Cookies

    /// Parse a `Cookie:` header into its pairs.
    public static func parseCookies(_ header: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            if !name.isEmpty { out[name] = value }
        }
        return out
    }

    /// The `Set-Cookie` value for a minted or rotated session.
    ///
    /// `HttpOnly` so XSS cannot read it, `Secure` so it is not sent in clear,
    /// `SameSite` so it is not sent from another site's form, `Path=/` so one
    /// session covers the application, and `Max-Age` matching the absolute
    /// expiry so a browser discards what the server has already forgotten.
    public func setCookieHeader(for cookieValue: String) -> String {
        var attributes = ["\(policy.cookieName)=\(cookieValue)",
                          "Path=/",
                          "HttpOnly",
                          "SameSite=\(policy.sameSite)",
                          "Max-Age=\(Int(policy.absoluteTimeout))"]
        if policy.requiresSecureTransport { attributes.append("Secure") }
        return attributes.joined(separator: "; ")
    }

    /// The header that clears a session cookie, for logout.
    public func clearCookieHeader() -> String {
        "\(policy.cookieName)=; Path=/; HttpOnly; SameSite=\(policy.sameSite); Max-Age=0"
    }

    // MARK: - Origin (§8.2)

    /// Whether a WebSocket upgrade's `Origin` is one this application accepts.
    ///
    /// `SameSite` does not reliably cover a WebSocket handshake, so without
    /// this a cookie-authenticated socket can be opened by any page the user
    /// visits. Refusing when nothing is configured is deliberate: the safe
    /// default for an unanswered security question is no.
    public func isAcceptableOrigin(_ origin: String?) -> Bool {
        guard !policy.allowedOrigins.isEmpty else { return false }
        guard let origin, !origin.isEmpty else { return false }
        return policy.allowedOrigins.contains(origin)
    }
}

/// What can go wrong while establishing a session.
public enum SessionError: Error, CustomStringConvertible, Equatable {
    case insecureTransport
    case noSuchSession(String)
    case alreadyAttached(connection: String, session: String)

    public var description: String {
        switch self {
        case .insecureTransport:
            return "refusing to issue a session cookie over plain HTTP — "
                 + "serve over TLS, or configure the session with { secure: false } for local development"
        case .noSuchSession(let id):
            return "no session '\(id)' in the \(SessionRepositories.sessions)"
        case .alreadyAttached(let connection, let session):
            return "connection \(connection) is already attached to session \(session); "
                 + "a connection cannot change session — close it instead"
        }
    }
}

/// Where an `Attach` leaves the cookie it minted, for the HTTP handler to put
/// on the response.
///
/// A class rather than a return value because the statement that mints the
/// session is somewhere inside a feature set and the header goes on a response
/// the handler builds afterwards. Registered as a service on the request's
/// context, so nothing global is involved and two concurrent requests cannot
/// see each other's cookie.
public final class PendingSessionCookie: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    public init() {}

    public var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// The connection an execution arrived on, when it arrived on one.
///
/// A WebSocket frame and a socket packet both know their connection; an HTTP
/// request does not have one the program can see. Registered as a service so
/// `Attach` can promote the connection it is actually running for rather than
/// taking the id as an argument nobody can be trusted to pass correctly.
public final class ConnectionIdentity: @unchecked Sendable {
    public let id: String
    public let transport: String
    public init(id: String, transport: String) {
        self.id = id
        self.transport = transport
    }
}


/// The current policy, readable without awaiting the actor.
///
/// SwiftNIO's upgrade path is not async: `shouldUpgrade` must answer with an
/// `EventLoopFuture`, and deciding whether to refuse an `Origin` there is the
/// difference between rejecting a cross-site handshake and accepting it and
/// tearing it down afterwards. So the policy — which changes once, at startup —
/// is mirrored here behind a lock, and the actor stays the owner of everything
/// that actually touches session state.
public final class SessionPolicyStore: @unchecked Sendable {

    public static let shared = SessionPolicyStore()

    private let lock = NSLock()
    private var stored = SessionPolicy()

    public var policy: SessionPolicy {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
