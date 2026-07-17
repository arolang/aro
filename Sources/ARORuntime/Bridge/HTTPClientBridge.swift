// ============================================================
// HTTPClientBridge.swift
// ARORuntime - C-callable HTTP Client Interface
// ============================================================
//
// Owns the C-ABI bridge for outbound HTTP requests/responses
// (request handle, method/header/body setters, execute, response accessors).
// Extracted from ServiceBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AROParser

#if !os(Windows)

// MARK: - HTTP Client Bridge

/// HTTP request handle for C interop
final class HTTPRequestHandle: @unchecked Sendable {
    var url: String = ""
    var method: String = "GET"
    var headers: [String: String] = [:]
    var body: Data?
    var response: HTTPResponseHandle?

    init() {}
}

/// HTTP response handle for C interop
final class HTTPResponseHandle: @unchecked Sendable {
    var statusCode: Int = 0
    var headers: [String: String] = [:]
    var body: Data?

    init() {}
}

/// Create an HTTP request
/// - Parameter url: Request URL (C string)
/// - Returns: Request handle
@_cdecl("aro_http_request_create")
public func aro_http_request_create(_ url: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    let handle = HTTPRequestHandle()
    handle.url = url.map { String(cString: $0) } ?? ""

    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Set request method
/// - Parameters:
///   - requestPtr: Request handle
///   - method: HTTP method (C string)
@_cdecl("aro_http_request_set_method")
public func aro_http_request_set_method(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ method: UnsafePointer<CChar>?
) {
    guard let ptr = requestPtr,
          let methodStr = method.map({ String(cString: $0) }) else { return }

    let handle = Unmanaged<HTTPRequestHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.method = methodStr
}

/// Set request header
/// - Parameters:
///   - requestPtr: Request handle
///   - name: Header name (C string)
///   - value: Header value (C string)
@_cdecl("aro_http_request_set_header")
public func aro_http_request_set_header(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?
) {
    guard let ptr = requestPtr,
          let nameStr = name.map({ String(cString: $0) }),
          let valueStr = value.map({ String(cString: $0) }) else { return }

    let handle = Unmanaged<HTTPRequestHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.headers[nameStr] = valueStr
}

/// Set request body
/// - Parameters:
///   - requestPtr: Request handle
///   - body: Body data
///   - length: Body length
@_cdecl("aro_http_request_set_body")
public func aro_http_request_set_body(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ body: UnsafePointer<UInt8>?,
    _ length: Int
) {
    guard let ptr = requestPtr,
          let bodyPtr = body else { return }

    let handle = Unmanaged<HTTPRequestHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.body = Data(bytes: bodyPtr, count: length)
}

/// Execute the HTTP request (blocking)
/// - Parameter requestPtr: Request handle
/// - Returns: Response handle or NULL on error
/// Result holder for async HTTP requests
private final class HTTPRequestResultHolder: @unchecked Sendable {
    var response: HTTPResponseHandle?
}

@_cdecl("aro_http_request_execute")
public func aro_http_request_execute(_ requestPtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    guard let ptr = requestPtr else { return nil }

    let handle = Unmanaged<HTTPRequestHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Create a semaphore to wait for async completion
    let semaphore = DispatchSemaphore(value: 0)
    let resultHolder = HTTPRequestResultHolder()

    Task { [handle, resultHolder] in
        do {
            guard let url = URL(string: handle.url) else {
                semaphore.signal()
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = handle.method

            for (name, value) in handle.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }

            if let body = handle.body {
                request.httpBody = body
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            let resp = HTTPResponseHandle()
            if let httpResponse = response as? HTTPURLResponse {
                resp.statusCode = httpResponse.statusCode
                for (key, value) in httpResponse.allHeaderFields {
                    if let k = key as? String, let v = value as? String {
                        resp.headers[k] = v
                    }
                }
            }
            resp.body = data
            resultHolder.response = resp
        } catch {
            print("[ARO] HTTP request error: \(error)")
        }

        semaphore.signal()
    }

    semaphore.wait()

    if let resp = resultHolder.response {
        return UnsafeMutableRawPointer(Unmanaged.passRetained(resp).toOpaque())
    }
    return nil
}

/// Get response status code
/// - Parameter responsePtr: Response handle
/// - Returns: HTTP status code
@_cdecl("aro_http_response_status")
public func aro_http_response_status(_ responsePtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = responsePtr else { return 0 }

    let handle = Unmanaged<HTTPResponseHandle>.fromOpaque(ptr).takeUnretainedValue()
    return Int32(handle.statusCode)
}

/// Get response body
/// - Parameters:
///   - responsePtr: Response handle
///   - outLength: Pointer to store body length
/// - Returns: Pointer to body data (do not free)
@_cdecl("aro_http_response_body")
public func aro_http_response_body(
    _ responsePtr: UnsafeMutableRawPointer?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafePointer<UInt8>? {
    guard let ptr = responsePtr else { return nil }

    let handle = Unmanaged<HTTPResponseHandle>.fromOpaque(ptr).takeUnretainedValue()

    guard let body = handle.body else {
        outLength?.pointee = 0
        return nil
    }

    outLength?.pointee = body.count
    return body.withUnsafeBytes { $0.baseAddress?.assumingMemoryBound(to: UInt8.self) }
}

/// Free HTTP request
@_cdecl("aro_http_request_destroy")
public func aro_http_request_destroy(_ requestPtr: UnsafeMutableRawPointer?) {
    guard let ptr = requestPtr else { return }
    Unmanaged<HTTPRequestHandle>.fromOpaque(ptr).release()
}

/// Free HTTP response
@_cdecl("aro_http_response_destroy")
public func aro_http_response_destroy(_ responsePtr: UnsafeMutableRawPointer?) {
    guard let ptr = responsePtr else { return }
    Unmanaged<HTTPResponseHandle>.fromOpaque(ptr).release()
}

#else  // os(Windows)

// MARK: - HTTP Client Stubs (Windows)

/// Create an HTTP request (Windows stub)
@_cdecl("aro_http_request_create")
public func aro_http_request_create(_ url: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    return nil
}

/// Set request method (Windows stub)
@_cdecl("aro_http_request_set_method")
public func aro_http_request_set_method(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ method: UnsafePointer<CChar>?
) {
    // No-op
}

/// Set request header (Windows stub)
@_cdecl("aro_http_request_set_header")
public func aro_http_request_set_header(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?
) {
    // No-op
}

/// Set request body (Windows stub)
@_cdecl("aro_http_request_set_body")
public func aro_http_request_set_body(
    _ requestPtr: UnsafeMutableRawPointer?,
    _ body: UnsafePointer<UInt8>?,
    _ length: Int
) {
    // No-op
}

/// Execute the HTTP request (Windows stub)
@_cdecl("aro_http_request_execute")
public func aro_http_request_execute(_ requestPtr: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    return nil
}

/// Get response status code (Windows stub)
@_cdecl("aro_http_response_status")
public func aro_http_response_status(_ responsePtr: UnsafeMutableRawPointer?) -> Int32 {
    return 0
}

/// Get response body (Windows stub)
@_cdecl("aro_http_response_body")
public func aro_http_response_body(
    _ responsePtr: UnsafeMutableRawPointer?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafePointer<UInt8>? {
    outLength?.pointee = 0
    return nil
}

/// Free HTTP request (Windows stub)
@_cdecl("aro_http_request_destroy")
public func aro_http_request_destroy(_ requestPtr: UnsafeMutableRawPointer?) {
    // No-op
}

/// Free HTTP response (Windows stub)
@_cdecl("aro_http_response_destroy")
public func aro_http_response_destroy(_ responsePtr: UnsafeMutableRawPointer?) {
    // No-op
}

#endif  // !os(Windows)
