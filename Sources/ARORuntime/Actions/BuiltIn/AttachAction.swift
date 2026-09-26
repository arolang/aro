// ============================================================
// AttachAction.swift
// ARO Runtime — Attach the <session> to the <connection>.
// ARO-0094 §6.1, GitLab #885
// ============================================================
//
// `Attach` answers one question — who is this caller? — and it is the only
// statement that changes the answer. Keeping it to one verb is what makes the
// audit tractable: every place an ARO program can gain an identity is a line
// that says `Attach`.
//
// Two objects, because the two transports differ in what they can be attached
// to and in nothing else:
//
//   Attach the <session> to the <connection>.   (* TCP, WebSocket — §6.1 *)
//   Attach the <session> to the <caller>.       (* HTTP — sets the cookie *)
//
// Promotion is not reversible within a connection. A connection that has been
// a session cannot become anonymous or become a *different* session, because
// either is a downgrade attack written in one statement. Closing the socket is
// how a peer stops being that session.

import Foundation
import AROParser

/// `Attach the <session> to the <connection>.` — says who a caller is.
public struct AttachAction: ActionImplementation {

    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["attach"]
    public static let validPrepositions: Set<Preposition> = [.to, .with]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {

        let target = object.base.lowercased()
        guard target == "connection" || target == "caller" || target == "request" else {
            throw ActionError.invalidInput(
                "Attach the <\(result.base)> to the <connection> (a socket or WebSocket) "
                + "or to the <caller> (an HTTP request)",
                received: object.base)
        }

        // The session being attached: either a record the program built, or a
        // record it retrieved from the sessions repository.
        let presented = context.resolveAny(result.base)
            ?? context.resolveAny("_with_")
            ?? context.resolveAny("_literal_")
        guard let session = Self.firstRecord(in: presented) else {
            throw ActionError.invalidInput(
                "Attach expects a session record — retrieve one from the "
                + "\(SessionRepositories.sessions), or write the fields to mint one",
                received: String(describing: presented))
        }

        let service = SessionService.shared
        let existingId = (session["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // A record with an id names a session that must already exist (§6.1);
        // a record without one *describes* a session to mint. The difference
        // matters: silently minting for an id that turned out to be stale
        // would turn a revoked session into a fresh valid one.
        let sessionId: String
        var mintedCookie: String?
        if let existingId {
            sessionId = existingId
        } else {
            let secure = Self.isSecureTransport(context)
            let minted = try await service.mint(fields: session, overSecureTransport: secure)
            sessionId = minted.id
            mintedCookie = minted.cookieValue
        }

        switch target {
        case "connection":
            guard let connection = context.service(ConnectionIdentity.self) else {
                throw ActionError.invalidInput(
                    "Attach the <\(result.base)> to the <connection>: this feature set is not "
                    + "running for a connection — use <caller> for an HTTP request",
                    received: context.businessActivity)
            }
            try await service.attach(sessionId: sessionId, toConnection: connection.id)

        case "caller", "request":
            // HTTP has no connection the program can see, so the attachment is
            // the cookie. A session that already existed still gets one: the
            // request that authenticated may not be the request that presented
            // the cookie.
            let cookie: String?
            if let mintedCookie {
                cookie = mintedCookie
            } else {
                cookie = await service.rotate(sessionId: sessionId)
            }
            guard let cookie else {
                throw ActionError.invalidInput(
                    SessionError.noSuchSession(sessionId).description,
                    received: sessionId)
            }
            guard let pending = context.service(PendingSessionCookie.self) else {
                throw ActionError.invalidInput(
                    "Attach the <\(result.base)> to the <caller>: this feature set is not "
                    + "handling an HTTP request, so there is no response to set a cookie on",
                    received: context.featureSetName)
            }
            pending.value = await service.setCookieHeader(for: cookie)

        default:
            break
        }

        // No result binding. The slot names *which* session to attach, the way
        // `Store the <a> into the <repo>` names what to store, and the session
        // it names was retrieved on the line above — rebinding it here would
        // shadow the record the program already has.
        var record = session
        record["id"] = sessionId
        return record
    }

    /// `Retrieve` binds a single record when a `where` clause matched exactly
    /// one row and a list otherwise, so `Attach` accepts either (GitLab #835).
    private static func firstRecord(in value: (any Sendable)?) -> [String: any Sendable]? {
        if let record = value as? [String: any Sendable] { return record }
        if let list = value as? [any Sendable] {
            return list.compactMap { $0 as? [String: any Sendable] }.first
        }
        return nil
    }

    /// Whether the request arrived over TLS. `Configure the <http-server: tls>`
    /// and a terminating proxy's `X-Forwarded-Proto` are both honoured; local
    /// development turns the requirement off explicitly rather than by accident.
    private static func isSecureTransport(_ context: ExecutionContext) -> Bool {
        if let forwarded: String = context.resolve("_x_forwarded_proto_") {
            return forwarded.lowercased() == "https"
        }
        if let tls: Bool = context.resolve("_http_tls_") { return tls }
        return ProcessInfo.processInfo.environment["ARO_HTTP_TLS"] == "1"
    }
}
