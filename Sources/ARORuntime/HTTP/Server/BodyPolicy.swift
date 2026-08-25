// ============================================================
// BodyPolicy.swift
// ARO Runtime - Per-route request body policy (GitLab #477)
// ============================================================
//
// Streams don't have a size. Values do.
//
// A request body that a feature set only *moves* — to a file, to
// a socket, to the response — is never a value, so its size is
// bounded by the sink rather than by memory. A body a feature set
// *reads* becomes a value, and that is the only thing with a
// limit.
//
// Which of the two a route is, is decided by the materialization
// analysis (`BodyMaterialization` in AROParser) before the server
// binds a port, and reaches the server as one of these policies.

import Foundation

/// What the server may do with the body of one route's requests.
public struct BodyPolicy: Sendable, Equatable {

    /// How the body reaches the feature set.
    public enum Mode: Sendable, Equatable {
        /// The feature set reads the body as a value. It is accumulated in
        /// memory and bounded by `limit`.
        case buffered
        /// The feature set only moves the body. Nothing is accumulated; the
        /// bytes flow from the socket to the sink under backpressure.
        case streamed
    }

    public let mode: Mode

    /// Maximum bytes the server will accept on the wire, or `nil` for no
    /// limit.
    ///
    /// Always set for `.buffered` — that is the memory bound, and the reason
    /// an oversized `Content-Length` can be refused at the request head. Nil
    /// for `.streamed`: nothing accumulates, so there is nothing for a
    /// transport limit to protect, and the sink imposes its own.
    public let limit: Int?

    /// Maximum bytes that may become a value if some statement does read the
    /// body after all. On a buffered route this is the same number as `limit`;
    /// on a streamed route it is the declared `x-aro-max-body`, held in
    /// reserve for the safety net rather than applied to the wire.
    public let materializationLimit: Int

    public init(mode: Mode, limit: Int?, materializationLimit: Int) {
        self.mode = mode
        self.limit = limit
        self.materializationLimit = materializationLimit
    }

    public static func buffered(limit: Int) -> BodyPolicy {
        BodyPolicy(mode: .buffered, limit: limit, materializationLimit: limit)
    }

    public static func streamed(materializationLimit: Int) -> BodyPolicy {
        BodyPolicy(mode: .streamed, limit: nil, materializationLimit: materializationLimit)
    }

    /// The policy for a route nothing is known about: buffer it, bounded by
    /// the global default. Unknown code is assumed to read its body, because
    /// assuming the opposite is the assumption that loses memory.
    public static var `default`: BodyPolicy {
        .buffered(limit: RuntimeDefaults.maxMaterializedBody)
    }
}

/// A request body that has not been read yet.
///
/// Carries chunks, not bytes. The producer is the connection and the consumer
/// is whatever the feature set does with `<request: body>` — a file, a socket,
/// the response. Reading it as a value is possible (`materialize`) and is what
/// `limit` bounds.
///
/// It can be consumed **once**: the bytes arrive from the network exactly one
/// time and are not retained. A second consumer is a program error, reported
/// as one.
public struct RequestBodyStream: Sendable {
    /// The chunks, in arrival order.
    public let chunks: AROStream<Data>

    /// `Content-Length`, when the client declared one. Absent for chunked
    /// transfer encoding, which is the case a limit has to be enforced
    /// incrementally rather than up front.
    public let declaredLength: Int?

    /// The route's materialization limit, carried so that the error raised by
    /// reading too much can name the number that was exceeded.
    public let limit: Int?

    public init(chunks: AROStream<Data>, declaredLength: Int?, limit: Int?) {
        self.chunks = chunks
        self.declaredLength = declaredLength
        self.limit = limit
    }
}

/// Resolves the policy for one request, from its method and path.
///
/// Installed on the server by `Application` once the contract and the
/// analysis are both known, and consulted at the request head — before a
/// body byte is read — so an oversized `Content-Length` can be refused
/// without allocating anything.
public typealias BodyPolicyResolver = @Sendable (_ method: String, _ path: String) -> BodyPolicy
