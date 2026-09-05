// ============================================================
// ZMQ.swift
// aro kernel — the minimal libzmq wrapper the kernel needs
// ============================================================
//
// Five sockets, three patterns (ROUTER, PUB, REP), bind-only,
// blocking I/O on dedicated threads. Deliberately not a general
// ZeroMQ binding: the Jupyter wire protocol needs exactly
// multipart receive and multipart send, and everything else libzmq
// offers is surface area this file would have to maintain.
//
// Thread-safety follows libzmq's own rule: a socket lives on one
// thread. The single exception, iopub, is serialized by the kernel
// server's lock (a full barrier, which is what migrating a socket
// between threads requires).

#if !os(Windows)
import Foundation
import CZeroMQ

/// @unchecked: the context handle is thread-safe by libzmq's own
/// contract (`zmq_ctx_*` may be called from any thread).
final class ZMQContext: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer

    init?() {
        guard let handle = zmq_ctx_new() else { return nil }
        self.handle = handle
    }

    /// Interrupts every blocking call on the context's sockets and
    /// makes further ones fail — the shutdown path for threads
    /// parked in `zmq_msg_recv`.
    func shutdown() {
        zmq_ctx_shutdown(handle)
    }

    deinit {
        zmq_ctx_term(handle)
    }
}

/// @unchecked: a socket is NOT thread-safe — the guarantee is
/// confinement, enforced by the kernel's thread model (each socket
/// lives on the thread running its loop; iopub is serialized by the
/// server's lock, a full barrier). `Sendable` here only lets the
/// dedicated `Thread { }` closures capture the socket they own.
final class ZMQSocket: @unchecked Sendable {
    enum Kind {
        case router
        case pub
        case rep
        /// Client side of REP — the kernel never uses it; tests do,
        /// to prove the loop from the other end of the wire.
        case req

        var raw: Int32 {
            switch self {
            case .router: return ZMQ_ROUTER
            case .pub:    return ZMQ_PUB
            case .rep:    return ZMQ_REP
            case .req:    return ZMQ_REQ
            }
        }
    }

    private let handle: UnsafeMutableRawPointer

    init?(context: ZMQContext, kind: Kind) {
        guard let handle = zmq_socket(context.handle, kind.raw) else { return nil }
        self.handle = handle
        // A lingering socket would block process exit while unsent
        // frames wait for a peer that already went away.
        var linger: Int32 = 0
        zmq_setsockopt(handle, ZMQ_LINGER, &linger, MemoryLayout<Int32>.size)
    }

    func bind(_ endpoint: String) throws {
        guard zmq_bind(handle, endpoint) == 0 else {
            throw ZMQError.bindFailed(endpoint: endpoint, message: Self.lastError())
        }
    }

    func connect(_ endpoint: String) throws {
        guard zmq_connect(handle, endpoint) == 0 else {
            throw ZMQError.bindFailed(endpoint: endpoint, message: Self.lastError())
        }
    }

    /// Receive one whole multipart message. Blocks. Returns nil when
    /// the context shut down (or the call failed) — the caller's cue
    /// to exit its loop.
    func receiveMultipart() -> [Data]? {
        var frames: [Data] = []
        while true {
            var message = zmq_msg_t()
            zmq_msg_init(&message)
            guard zmq_msg_recv(&message, handle, 0) >= 0 else {
                zmq_msg_close(&message)
                return nil
            }
            let size = zmq_msg_size(&message)
            if size > 0, let bytes = zmq_msg_data(&message) {
                frames.append(Data(bytes: bytes, count: size))
            } else {
                frames.append(Data())
            }
            let more = zmq_msg_get(&message, ZMQ_MORE)
            zmq_msg_close(&message)
            if more == 0 { break }
        }
        return frames
    }

    /// Send one whole multipart message.
    func sendMultipart(_ frames: [Data]) {
        for (index, frame) in frames.enumerated() {
            let flags = index == frames.count - 1 ? 0 : ZMQ_SNDMORE
            frame.withUnsafeBytes { raw in
                _ = zmq_send(handle, raw.baseAddress, frame.count, flags)
            }
        }
    }

    func close() {
        zmq_close(handle)
    }

    private static func lastError() -> String {
        String(cString: zmq_strerror(zmq_errno()))
    }
}

enum ZMQError: Error, CustomStringConvertible {
    case bindFailed(endpoint: String, message: String)

    var description: String {
        switch self {
        case .bindFailed(let endpoint, let message):
            return "zmq_bind(\(endpoint)) failed: \(message)"
        }
    }
}
#endif
