// ============================================================
// HTTPServerBridge.swift
// ARORuntime - C-callable HTTP Server Interface
// ============================================================
//
// Owns the C-ABI bridge for the AROHTTPServer handle (create/start/stop/
// destroy/route). Extracted from ServiceBridge.swift (issue #313) — pure
// move, no behaviour change.

import Foundation
import AROParser

#if !os(Windows)

// MARK: - HTTP Server Bridge

/// HTTP server handle for C interop
final class HTTPServerHandle: @unchecked Sendable {
    var server: AROHTTPServer?
    var isRunning: Bool = false

    init() {}
}

nonisolated(unsafe) private var httpServerHandles: [UnsafeMutableRawPointer: HTTPServerHandle] = [:]
private let serverLock = NSLock()

/// Create an HTTP server
/// - Parameter runtimePtr: Runtime handle
/// - Returns: HTTP server handle
@_cdecl("aro_http_server_create")
public func aro_http_server_create(_ runtimePtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    let handle = HTTPServerHandle()
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    serverLock.lock()
    httpServerHandles[pointer] = handle
    serverLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}

/// Start the HTTP server
/// - Parameters:
///   - serverPtr: Server handle
///   - host: Host to bind (C string)
///   - port: Port number
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_http_server_start")
public func aro_http_server_start(
    _ serverPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    guard let ptr = serverPtr else { return -1 }

    let handle = Unmanaged<HTTPServerHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Create server
    handle.server = AROHTTPServer()

    // Start server using async context
    Task {
        do {
            try await handle.server?.start(port: Int(port))
            handle.isRunning = true
        } catch {
            print("[ARO] HTTP server error: \(error)")
        }
    }

    return 0
}

/// Stop the HTTP server
/// - Parameter serverPtr: Server handle
@_cdecl("aro_http_server_stop")
public func aro_http_server_stop(_ serverPtr: UnsafeMutableRawPointer?) {
    guard let ptr = serverPtr else { return }

    let handle = Unmanaged<HTTPServerHandle>.fromOpaque(ptr).takeUnretainedValue()

    Task {
        try? await handle.server?.stop()
        handle.isRunning = false
    }
}

/// Destroy the HTTP server
/// - Parameter serverPtr: Server handle
@_cdecl("aro_http_server_destroy")
public func aro_http_server_destroy(_ serverPtr: UnsafeMutableRawPointer?) {
    guard let ptr = serverPtr else { return }

    serverLock.lock()
    httpServerHandles.removeValue(forKey: ptr)
    serverLock.unlock()

    Unmanaged<HTTPServerHandle>.fromOpaque(ptr).release()
}

/// Register a route handler
/// - Parameters:
///   - serverPtr: Server handle
///   - method: HTTP method (C string)
///   - path: Route path (C string)
///   - handler: Callback function pointer
@_cdecl("aro_http_server_route")
public func aro_http_server_route(
    _ serverPtr: UnsafeMutableRawPointer?,
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ handler: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?)?
) {
    guard let ptr = serverPtr,
          let methodStr = method.map({ String(cString: $0) }),
          let pathStr = path.map({ String(cString: $0) }) else { return }

    _ = Unmanaged<HTTPServerHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Store route information (actual routing would need more work)
    print("[ARO] Registered route: \(methodStr) \(pathStr)")
}

#else  // os(Windows)

// MARK: - HTTP Server Stubs (Windows)

/// Create an HTTP server (Windows stub)
@_cdecl("aro_http_server_create")
public func aro_http_server_create(_ runtimePtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    return nil
}

/// Start the HTTP server (Windows stub)
@_cdecl("aro_http_server_start")
public func aro_http_server_start(
    _ serverPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    return -1
}

/// Stop the HTTP server (Windows stub)
@_cdecl("aro_http_server_stop")
public func aro_http_server_stop(_ serverPtr: UnsafeMutableRawPointer?) {
    // No-op
}

/// Destroy the HTTP server (Windows stub)
@_cdecl("aro_http_server_destroy")
public func aro_http_server_destroy(_ serverPtr: UnsafeMutableRawPointer?) {
    // No-op
}

/// Register a route handler (Windows stub)
@_cdecl("aro_http_server_route")
public func aro_http_server_route(
    _ serverPtr: UnsafeMutableRawPointer?,
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ handler: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?)?
) {
    // No-op
}

#endif  // !os(Windows)
