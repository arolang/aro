// ============================================================
// DAPTCPListener.swift
// ARO Runtime - TCP socket bridge for the DAP frontend (Phase 5)
// ============================================================
//
// Issue #229 Phase 5 — production attach. The CLI exposes a port via
// `--dap-port`; this listener accepts exactly one client and wraps the
// socket in FileHandles that `DAPFrontend` consumes the same way it
// consumes stdio. The full production story (`aro debug --attach pid`,
// remote DAP over WebSocket for Cloudflare Worker / Lambda deploys) is
// noted in #229 Phase 5 — Unix-domain-socket variant and a WebSocket
// upgrade can both reuse this glue.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum DAPTCPListener {

    public struct Endpoint: Sendable {
        public let input: FileHandle
        public let output: FileHandle
        public let socketFd: Int32
    }

    /// Bind to `127.0.0.1:port`, accept one connection, return matched
    /// FileHandles. Blocks the calling thread until a connection arrives
    /// — run on a detached task.
    public static func acceptOne(port: UInt16) throws -> Endpoint {
        let fd = socket(AF_INET, SOCK_STREAM_VALUE, 0)
        guard fd >= 0 else {
            throw NSError(domain: "DAPTCPListener", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket()"])
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0 else {
            close(fd)
            throw NSError(domain: "DAPTCPListener", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind(127.0.0.1:\(port)) failed"])
        }
        guard listen(fd, 1) == 0 else {
            close(fd)
            throw NSError(domain: "DAPTCPListener", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(fd, sa, &clientLen)
            }
        }
        close(fd)
        guard clientFD >= 0 else {
            throw NSError(domain: "DAPTCPListener", code: 4, userInfo: [NSLocalizedDescriptionKey: "accept() failed"])
        }
        let input = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        let output = FileHandle(fileDescriptor: clientFD, closeOnDealloc: false)
        return Endpoint(input: input, output: output, socketFd: clientFD)
    }
}

// SOCK_STREAM has a different declared type on Darwin (Int32) vs Glibc
// (UInt32). Normalize to Int32 via a constant the call site can use
// without conditional compilation.
#if canImport(Darwin)
fileprivate let SOCK_STREAM_VALUE: Int32 = SOCK_STREAM
#else
fileprivate let SOCK_STREAM_VALUE: Int32 = Int32(SOCK_STREAM.rawValue)
#endif
