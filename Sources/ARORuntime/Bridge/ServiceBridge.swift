// ============================================================
// ServiceBridge.swift
// ARORuntime - C-callable Service Interface
// ============================================================
//
// This file provides C-callable functions for HTTP, File, and Socket
// services in compiled ARO binaries.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AROParser

#if os(macOS)
import CoreServices
import CommonCrypto
#elseif os(Linux)
import Crypto
#endif

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

// MARK: - File System Bridge

/// Read a file
/// - Parameters:
///   - path: File path (C string)
///   - outLength: Pointer to store content length
/// - Returns: File content (caller must free with free())
@_cdecl("aro_file_read")
public func aro_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let content = try String(contentsOfFile: pathStr, encoding: .utf8)
        outLength?.pointee = content.utf8.count
        return strdup(content)
    } catch {
        print("[ARO] File read error: \(error)")
        return nil
    }
}

/// Write a file
/// - Parameters:
///   - path: File path (C string)
///   - content: File content (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_write")
public func aro_file_write(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    do {
        try contentStr.write(toFile: pathStr, atomically: true, encoding: .utf8)
        return 0
    } catch {
        print("[ARO] File write error: \(error)")
        return -1
    }
}

/// Check if file exists
/// - Parameter path: File path (C string)
/// - Returns: 1 if exists, 0 if not
@_cdecl("aro_file_exists")
public func aro_file_exists(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }
    return FileManager.default.fileExists(atPath: pathStr) ? 1 : 0
}

/// Delete a file
/// - Parameter path: File path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_delete")
public func aro_file_delete(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.removeItem(atPath: pathStr)
        return 0
    } catch {
        print("[ARO] File delete error: \(error)")
        return -1
    }
}

/// Create a directory
/// - Parameters:
///   - path: Directory path (C string)
///   - recursive: Create intermediate directories
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_directory_create")
public func aro_directory_create(
    _ path: UnsafePointer<CChar>?,
    _ recursive: Int32
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.createDirectory(
            atPath: pathStr,
            withIntermediateDirectories: recursive != 0,
            attributes: nil
        )
        return 0
    } catch {
        print("[ARO] Directory create error: \(error)")
        return -1
    }
}

/// List directory contents
/// - Parameters:
///   - path: Directory path (C string)
///   - outCount: Pointer to store entry count
/// - Returns: Array of C strings (caller must free each string and the array)
@_cdecl("aro_directory_list")
public func aro_directory_list(
    _ path: UnsafePointer<CChar>?,
    _ outCount: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: pathStr)
        outCount?.pointee = entries.count

        let result = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: entries.count)
        for (i, entry) in entries.enumerated() {
            result[i] = strdup(entry)
        }
        return result
    } catch {
        print("[ARO] Directory list error: \(error)")
        return nil
    }
}

// MARK: - ARO-0036 Extended File Operations

/// Get file stats as JSON string
/// - Parameters:
///   - path: File path (C string)
///   - outLength: Pointer to store JSON length
/// - Returns: JSON string with file stats (caller must free with free())
@_cdecl("aro_file_stat")
public func aro_file_stat(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let url = URL(fileURLWithPath: pathStr)
        let attributes = try FileManager.default.attributesOfItem(atPath: pathStr)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let size = (attributes[.size] as? Int) ?? 0
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date
        let posixPermissions = attributes[.posixPermissions] as? Int

        // Format permissions
        let permChars = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        var permissions = ""
        if let perm = posixPermissions {
            let owner = (perm >> 6) & 0o7
            let group = (perm >> 3) & 0o7
            let other = perm & 0o7
            permissions = permChars[owner] + permChars[group] + permChars[other]
        }

        // Build JSON response
        var json: [String: Any] = [
            "name": url.lastPathComponent,
            "path": url.path,
            "size": size,
            "isFile": !isDirectory,
            "isDirectory": isDirectory
        ]

        let dateFormatter = ISO8601DateFormatter()
        if let c = created {
            json["created"] = dateFormatter.string(from: c)
        }
        if let m = modified {
            json["modified"] = dateFormatter.string(from: m)
        }
        if !permissions.isEmpty {
            json["permissions"] = permissions
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            outLength?.pointee = jsonStr.utf8.count
            return strdup(jsonStr)
        }
    } catch {
        print("[ARO] File stat error: \(error)")
    }
    return nil
}

/// List directory with pattern and recursive options, returns JSON
/// - Parameters:
///   - path: Directory path (C string)
///   - pattern: Glob pattern (C string, nullable)
///   - recursive: 1 for recursive, 0 for non-recursive
///   - outLength: Pointer to store JSON length
/// - Returns: JSON array of file entries (caller must free with free())
@_cdecl("aro_directory_list_extended")
public func aro_directory_list_extended(
    _ path: UnsafePointer<CChar>?,
    _ pattern: UnsafePointer<CChar>?,
    _ recursive: Int32,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    let patternStr = pattern.map { String(cString: $0) }
    let isRecursive = recursive != 0
    let fm = FileManager.default

    do {
        var entries: [[String: Any]] = []
        let directoryURL = URL(fileURLWithPath: pathStr)
        let dateFormatter = ISO8601DateFormatter()

        if isRecursive {
            let enumerator = fm.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: []
            )

            while let url = enumerator?.nextObject() as? URL {
                if matchesGlobPattern(url.lastPathComponent, pattern: patternStr) {
                    if let entry = fileEntryDict(for: url, dateFormatter: dateFormatter) {
                        entries.append(entry)
                    }
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

            for url in contents {
                if matchesGlobPattern(url.lastPathComponent, pattern: patternStr) {
                    if let entry = fileEntryDict(for: url, dateFormatter: dateFormatter) {
                        entries.append(entry)
                    }
                }
            }
        }

        if let jsonData = try? JSONSerialization.data(withJSONObject: entries),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            outLength?.pointee = jsonStr.utf8.count
            return strdup(jsonStr)
        }
    } catch {
        print("[ARO] Directory list extended error: \(error)")
    }
    return nil
}

/// Check if path exists with type info
/// - Parameters:
///   - path: Path to check (C string)
///   - outIsDirectory: Pointer to store 1 if directory, 0 if file
/// - Returns: 1 if exists, 0 if not
@_cdecl("aro_file_exists_with_type")
public func aro_file_exists_with_type(
    _ path: UnsafePointer<CChar>?,
    _ outIsDirectory: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }

    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: pathStr, isDirectory: &isDir)
    outIsDirectory?.pointee = isDir.boolValue ? 1 : 0
    return exists ? 1 : 0
}

/// Copy file or directory
/// - Parameters:
///   - source: Source path (C string)
///   - destination: Destination path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_copy")
public func aro_file_copy(
    _ source: UnsafePointer<CChar>?,
    _ destination: UnsafePointer<CChar>?
) -> Int32 {
    guard let srcStr = source.map({ String(cString: $0) }),
          let dstStr = destination.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default

    do {
        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: dstStr)
        let destDir = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fm.fileExists(atPath: dstStr) {
            try fm.removeItem(atPath: dstStr)
        }

        try fm.copyItem(atPath: srcStr, toPath: dstStr)
        return 0
    } catch {
        print("[ARO] File copy error: \(error)")
        return -1
    }
}

/// Move file or directory
/// - Parameters:
///   - source: Source path (C string)
///   - destination: Destination path (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_move")
public func aro_file_move(
    _ source: UnsafePointer<CChar>?,
    _ destination: UnsafePointer<CChar>?
) -> Int32 {
    guard let srcStr = source.map({ String(cString: $0) }),
          let dstStr = destination.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default

    do {
        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: dstStr)
        let destDir = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fm.fileExists(atPath: dstStr) {
            try fm.removeItem(atPath: dstStr)
        }

        try fm.moveItem(atPath: srcStr, toPath: dstStr)
        return 0
    } catch {
        print("[ARO] File move error: \(error)")
        return -1
    }
}

/// Append content to file
/// - Parameters:
///   - path: File path (C string)
///   - content: Content to append (C string)
/// - Returns: 0 on success, non-zero on error
@_cdecl("aro_file_append")
public func aro_file_append(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    let fm = FileManager.default
    let url = URL(fileURLWithPath: pathStr)

    do {
        if fm.fileExists(atPath: pathStr) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            if let data = contentStr.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            // Create parent directory if needed
            let parentDir = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parentDir.path) {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try contentStr.write(to: url, atomically: true, encoding: .utf8)
        }
        return 0
    } catch {
        print("[ARO] File append error: \(error)")
        return -1
    }
}

/// Helper: Check if filename matches glob pattern
private func matchesGlobPattern(_ name: String, pattern: String?) -> Bool {
    guard let pattern = pattern, !pattern.isEmpty else {
        return true
    }

    // Convert glob pattern to regex
    var regex = "^"
    for char in pattern {
        switch char {
        case "*": regex += ".*"
        case "?": regex += "."
        case ".": regex += "\\."
        case "[", "]": regex += String(char)
        default: regex += String(char)
        }
    }
    regex += "$"

    return (try? NSRegularExpression(pattern: regex, options: .caseInsensitive))?.firstMatch(
        in: name,
        options: [],
        range: NSRange(name.startIndex..., in: name)
    ) != nil
}

/// Helper: Create file entry dictionary for JSON serialization
private func fileEntryDict(for url: URL, dateFormatter: ISO8601DateFormatter) -> [String: Any]? {
    guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]) else {
        return nil
    }

    let isDirectory = resourceValues.isDirectory ?? false
    var entry: [String: Any] = [
        "name": url.lastPathComponent,
        "path": url.path,
        "size": resourceValues.fileSize ?? 0,
        "isFile": !isDirectory,
        "isDirectory": isDirectory
    ]

    if let created = resourceValues.creationDate {
        entry["created"] = dateFormatter.string(from: created)
    }
    if let modified = resourceValues.contentModificationDate {
        entry["modified"] = dateFormatter.string(from: modified)
    }

    return entry
}

// MARK: - File Watcher Bridge (Platform-specific)

#if os(macOS)
// ============================================================
// macOS Implementation using FSEvents
// ============================================================

/// File watcher handle using FSEvents (macOS)
final class FileWatcherHandle: @unchecked Sendable {
    var path: String
    var streamRef: FSEventStreamRef?
    var isWatching: Bool = false
    var lastEventId: FSEventStreamEventId = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    func stop() {
        if let stream = streamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            streamRef = nil
        }
        isWatching = false
    }
}

nonisolated(unsafe) private var fileWatcherHandles: [UnsafeMutableRawPointer: FileWatcherHandle] = [:]
private let watcherLock = NSLock()

/// FSEvents callback - called when file changes occur
private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallBackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    let paths = unsafeBitCast(eventPaths, to: NSArray.self)

    for i in 0..<numEvents {
        guard let path = paths[i] as? String else { continue }
        let flags = eventFlags[i]

        // Determine event type - FSEvents can set multiple flags at once
        // Check in priority order: Removed > Modified > Created > Renamed
        let eventType: String
        let isRemoved = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
        let isModified = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                         (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0
        let isCreated = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
        let isRenamed = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0

        if isRemoved {
            eventType = "Deleted"
        } else if isModified && !isCreated {
            // Modified but not created = file was edited
            eventType = "Modified"
        } else if isCreated && !isModified {
            // Created but not modified = new file
            eventType = "Created"
        } else if isCreated && isModified {
            // Both flags set - need to determine actual operation
            // Check if file exists to disambiguate
            if FileManager.default.fileExists(atPath: path) {
                // File exists, this is likely a modification
                eventType = "Modified"
            } else {
                // File doesn't exist, was probably created then immediately modified
                eventType = "Created"
            }
        } else if isRenamed {
            eventType = "Renamed"
        } else {
            continue // Skip unknown events
        }

        // Print to console (matching interpreter behavior)
        print("[FileMonitor] \(eventType): \(path)")
    }
}

/// Create a file watcher
@_cdecl("aro_file_watcher_create")
public func aro_file_watcher_create(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    // Resolve relative paths
    let resolvedPath: String
    if pathStr == "." {
        resolvedPath = FileManager.default.currentDirectoryPath
    } else if !pathStr.hasPrefix("/") {
        resolvedPath = FileManager.default.currentDirectoryPath + "/" + pathStr
    } else {
        resolvedPath = pathStr
    }

    // Verify path exists
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDir) else {
        print("[FileMonitor] Error: Path not found: \(resolvedPath)")
        return nil
    }

    let handle = FileWatcherHandle(path: resolvedPath)
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    watcherLock.lock()
    fileWatcherHandles[pointer] = handle
    watcherLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}

/// Start watching for file changes using FSEvents
@_cdecl("aro_file_watcher_start")
public func aro_file_watcher_start(_ watcherPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = watcherPtr else { return -1 }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Already watching
    if handle.isWatching { return 0 }

    // Create FSEvents stream
    var context = FSEventStreamContext(
        version: 0,
        info: ptr,
        retain: nil,
        release: nil,
        copyDescription: nil
    )

    let pathsToWatch = [handle.path] as CFArray

    guard let stream = FSEventStreamCreate(
        nil,
        fsEventsCallback,
        &context,
        pathsToWatch,
        handle.lastEventId,
        0.5, // Latency in seconds
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
    ) else {
        print("[FileMonitor] Error: Failed to create FSEvents stream")
        return -1
    }

    handle.streamRef = stream
    handle.isWatching = true

    // Schedule on a background queue
    let queue = DispatchQueue(label: "aro.filemonitor", qos: .utility)
    FSEventStreamSetDispatchQueue(stream, queue)

    // Start the stream
    if !FSEventStreamStart(stream) {
        print("[FileMonitor] Error: Failed to start FSEvents stream")
        handle.stop()
        return -1
    }

    print("[FileMonitor] Watching: \(handle.path)")
    return 0
}

/// Stop watching
@_cdecl("aro_file_watcher_stop")
public func aro_file_watcher_stop(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
}

/// Destroy file watcher
@_cdecl("aro_file_watcher_destroy")
public func aro_file_watcher_destroy(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    watcherLock.lock()
    fileWatcherHandles.removeValue(forKey: ptr)
    watcherLock.unlock()

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
    Unmanaged<FileWatcherHandle>.fromOpaque(ptr).release()
}

#elseif os(Linux)
// ============================================================
// Linux Implementation using inotify
// ============================================================

import Glibc

/// File watcher handle using inotify (Linux)
final class FileWatcherHandle: @unchecked Sendable {
    var path: String
    var inotifyFd: Int32 = -1
    var watchFd: Int32 = -1
    var isWatching: Bool = false
    var monitorThread: Thread?

    init(path: String) {
        self.path = path
    }

    deinit {
        stop()
    }

    func stop() {
        isWatching = false
        if watchFd >= 0 {
            inotify_rm_watch(inotifyFd, watchFd)
            watchFd = -1
        }
        if inotifyFd >= 0 {
            close(inotifyFd)
            inotifyFd = -1
        }
    }
}

nonisolated(unsafe) private var fileWatcherHandles: [UnsafeMutableRawPointer: FileWatcherHandle] = [:]
private let watcherLock = NSLock()

/// Create a file watcher
@_cdecl("aro_file_watcher_create")
public func aro_file_watcher_create(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    // Resolve relative paths
    let resolvedPath: String
    if pathStr == "." {
        resolvedPath = FileManager.default.currentDirectoryPath
    } else if !pathStr.hasPrefix("/") {
        resolvedPath = FileManager.default.currentDirectoryPath + "/" + pathStr
    } else {
        resolvedPath = pathStr
    }

    // Verify path exists
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        print("[FileMonitor] Error: Path not found: \(resolvedPath)")
        return nil
    }

    let handle = FileWatcherHandle(path: resolvedPath)
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    watcherLock.lock()
    fileWatcherHandles[pointer] = handle
    watcherLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}

/// Start watching for file changes using inotify
@_cdecl("aro_file_watcher_start")
public func aro_file_watcher_start(_ watcherPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = watcherPtr else { return -1 }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()

    if handle.isWatching { return 0 }

    // Initialize inotify
    handle.inotifyFd = inotify_init1(Int32(IN_NONBLOCK))
    if handle.inotifyFd < 0 {
        print("[FileMonitor] Error: Failed to initialize inotify")
        return -1
    }

    // Add watch for the directory
    let mask: UInt32 = UInt32(IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO)
    handle.watchFd = inotify_add_watch(handle.inotifyFd, handle.path, mask)
    if handle.watchFd < 0 {
        print("[FileMonitor] Error: Failed to add inotify watch")
        close(handle.inotifyFd)
        handle.inotifyFd = -1
        return -1
    }

    handle.isWatching = true
    print("[FileMonitor] Watching: \(handle.path)")

    // Start monitoring thread
    DispatchQueue.global(qos: .utility).async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while handle.isWatching {
            let length = read(handle.inotifyFd, &buffer, buffer.count)
            if length > 0 {
                var offset = 0
                while offset < length {
                    buffer.withUnsafeBufferPointer { bufferPtr in
                        let eventPtr = UnsafeRawPointer(bufferPtr.baseAddress! + offset)
                            .assumingMemoryBound(to: inotify_event.self)
                        let event = eventPtr.pointee

                        let eventType: String
                        if (event.mask & UInt32(IN_CREATE)) != 0 {
                            eventType = "Created"
                        } else if (event.mask & UInt32(IN_DELETE)) != 0 {
                            eventType = "Deleted"
                        } else if (event.mask & UInt32(IN_MODIFY)) != 0 {
                            eventType = "Modified"
                        } else if (event.mask & UInt32(IN_MOVED_FROM)) != 0 || (event.mask & UInt32(IN_MOVED_TO)) != 0 {
                            eventType = "Renamed"
                        } else {
                            return
                        }

                        if event.len > 0 {
                            let namePtr = UnsafeRawPointer(bufferPtr.baseAddress! + offset + MemoryLayout<inotify_event>.size)
                                .assumingMemoryBound(to: CChar.self)
                            let name = String(cString: namePtr)
                            let fullPath = handle.path + "/" + name
                            print("[FileMonitor] \(eventType): \(fullPath)")
                        }

                        offset += MemoryLayout<inotify_event>.size + Int(event.len)
                    }
                }
            } else {
                usleep(100000) // 100ms
            }
        }
    }

    return 0
}

/// Stop watching
@_cdecl("aro_file_watcher_stop")
public func aro_file_watcher_stop(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
}

/// Destroy file watcher
@_cdecl("aro_file_watcher_destroy")
public func aro_file_watcher_destroy(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    watcherLock.lock()
    fileWatcherHandles.removeValue(forKey: ptr)
    watcherLock.unlock()

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
    Unmanaged<FileWatcherHandle>.fromOpaque(ptr).release()
}

#else
// ============================================================
// Fallback Implementation (polling-based)
// ============================================================

/// File watcher handle using polling (Windows and other platforms)
final class FileWatcherHandle: @unchecked Sendable {
    var path: String
    var isWatching: Bool = false
    var lastModified: [String: Date] = [:]

    init(path: String) {
        self.path = path
    }

    func stop() {
        isWatching = false
    }
}

nonisolated(unsafe) private var fileWatcherHandles: [UnsafeMutableRawPointer: FileWatcherHandle] = [:]
private let watcherLock = NSLock()

/// Create a file watcher
@_cdecl("aro_file_watcher_create")
public func aro_file_watcher_create(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    // Resolve relative paths
    let resolvedPath: String
    if pathStr == "." {
        resolvedPath = FileManager.default.currentDirectoryPath
    } else {
        resolvedPath = pathStr
    }

    // Verify path exists
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
        print("[FileMonitor] Error: Path not found: \(resolvedPath)")
        return nil
    }

    let handle = FileWatcherHandle(path: resolvedPath)
    let pointer = Unmanaged.passRetained(handle).toOpaque()

    watcherLock.lock()
    fileWatcherHandles[pointer] = handle
    watcherLock.unlock()

    return UnsafeMutableRawPointer(pointer)
}

/// Start watching for file changes using polling
@_cdecl("aro_file_watcher_start")
public func aro_file_watcher_start(_ watcherPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = watcherPtr else { return -1 }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()

    if handle.isWatching { return 0 }
    handle.isWatching = true

    print("[FileMonitor] Watching: \(handle.path) (polling mode)")

    // Start polling thread
    DispatchQueue.global(qos: .utility).async {
        // Get initial file list
        var knownFiles: Set<String> = []
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: handle.path) {
            knownFiles = Set(contents)
            for file in contents {
                let fullPath = handle.path + "/" + file
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    handle.lastModified[file] = modDate
                }
            }
        }

        while handle.isWatching {
            Thread.sleep(forTimeInterval: 1.0) // Poll every second

            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: handle.path) else {
                continue
            }

            let currentFiles = Set(contents)

            // Check for new files
            for file in currentFiles.subtracting(knownFiles) {
                let fullPath = handle.path + "/" + file
                print("[FileMonitor] Created: \(fullPath)")
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    handle.lastModified[file] = modDate
                }
            }

            // Check for deleted files
            for file in knownFiles.subtracting(currentFiles) {
                let fullPath = handle.path + "/" + file
                print("[FileMonitor] Deleted: \(fullPath)")
                handle.lastModified.removeValue(forKey: file)
            }

            // Check for modified files
            for file in currentFiles.intersection(knownFiles) {
                let fullPath = handle.path + "/" + file
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    if let lastMod = handle.lastModified[file], modDate > lastMod {
                        print("[FileMonitor] Modified: \(fullPath)")
                    }
                    handle.lastModified[file] = modDate
                }
            }

            knownFiles = currentFiles
        }
    }

    return 0
}

/// Stop watching
@_cdecl("aro_file_watcher_stop")
public func aro_file_watcher_stop(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
}

/// Destroy file watcher
@_cdecl("aro_file_watcher_destroy")
public func aro_file_watcher_destroy(_ watcherPtr: UnsafeMutableRawPointer?) {
    guard let ptr = watcherPtr else { return }

    watcherLock.lock()
    fileWatcherHandles.removeValue(forKey: ptr)
    watcherLock.unlock()

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.stop()
    Unmanaged<FileWatcherHandle>.fromOpaque(ptr).release()
}

#endif

// MARK: - Native Socket Server (BSD Sockets)

#if canImport(Darwin)
import Darwin

@inline(__always)
private func systemClose(_ fd: Int32) -> Int32 {
    Darwin.close(fd)
}

@inline(__always)
private func systemSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ len: Int, _ flags: Int32) -> Int {
    Darwin.send(fd, buf, len, flags)
}
#elseif canImport(Glibc)
import Glibc

@inline(__always)
private func systemClose(_ fd: Int32) -> Int32 {
    Glibc.close(fd)
}

@inline(__always)
private func systemSend(_ fd: Int32, _ buf: UnsafeRawPointer!, _ len: Int, _ flags: Int32) -> Int {
    Glibc.send(fd, buf, len, flags)
}

private let SOCK_STREAM = Int32(Glibc.SOCK_STREAM.rawValue)
#endif

/// Native TCP Socket Server using BSD sockets
/// This provides a working socket server for compiled binaries
public final class NativeSocketServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let lock = NSLock()
    private var connections: [String: Int32] = [:]
    private var dataHandler: ((String, Data) -> Void)?
    private var connectHandler: ((String, String) -> Void)?
    private var disconnectHandler: ((String) -> Void)?

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    deinit {
        stop()
    }

    /// Set handler for incoming data
    public func onData(_ handler: @escaping (String, Data) -> Void) {
        dataHandler = handler
    }

    /// Set handler for new connections
    public func onConnect(_ handler: @escaping (String, String) -> Void) {
        connectHandler = handler
    }

    /// Set handler for disconnections
    public func onDisconnect(_ handler: @escaping (String) -> Void) {
        disconnectHandler = handler
    }

    /// Start the server
    public func start() -> Bool {
        // Create socket
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            print("[NativeSocketServer] Failed to create socket")
            return false
        }

        // Set SO_REUSEADDR
        var reuseAddr: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[NativeSocketServer] Failed to bind to port \(port)")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeSocketServer] Failed to listen")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        isRunning = true
        print("Socket Server started on port \(port)")

        // Start accept loop in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }

        return true
    }

    /// Stop the server
    public func stop() {
        isRunning = false

        lock.lock()
        let conns = connections
        connections.removeAll()
        lock.unlock()

        // Close all client connections
        for (_, fd) in conns {
            _ = systemClose(fd)
        }

        // Close server socket
        if serverFd >= 0 {
            _ = systemClose(serverFd)
            serverFd = -1
        }

        print("[NativeSocketServer] Stopped")
    }

    /// Send data to a specific connection
    public func send(data: Data, to connectionId: String) -> Bool {
        lock.lock()
        guard let fd = connections[connectionId] else {
            lock.unlock()
            print("[NativeSocketServer] Connection not found: \(connectionId)")
            return false
        }
        lock.unlock()

        let result = data.withUnsafeBytes { buffer in
            systemSend(fd, buffer.baseAddress!, data.count, 0)
        }

        return result >= 0
    }

    /// Broadcast data to all connections
    public func broadcast(data: Data) -> Int {
        lock.lock()
        let conns = connections
        lock.unlock()

        var successCount = 0
        for (_, fd) in conns {
            let result = data.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!, data.count, 0)
            }
            if result >= 0 {
                successCount += 1
            }
        }

        return successCount
    }

    /// Broadcast data to all connections except the sender
    public func broadcast(data: Data, excluding senderId: String) -> Int {
        lock.lock()
        let conns = connections
        lock.unlock()

        var successCount = 0
        for (connId, fd) in conns {
            if connId == senderId { continue }
            let result = data.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!, data.count, 0)
            }
            if result >= 0 {
                successCount += 1
            }
        }

        return successCount
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverFd, sockaddrPtr, &addrLen)
                }
            }

            guard clientFd >= 0, isRunning else { continue }

            let connectionId = UUID().uuidString
            let addrPtr = inet_ntoa(clientAddr.sin_addr)
            let remoteAddress = addrPtr != nil ? "[IPv4]\(String(cString: addrPtr!))" : "[IPv4]unknown"

            lock.lock()
            connections[connectionId] = clientFd
            lock.unlock()

            // Notify connect handler
            connectHandler?(connectionId, remoteAddress)

            // Handle client in background
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(fd: clientFd, connectionId: connectionId)
            }
        }
    }

    private func handleClient(fd: Int32, connectionId: String) {
        var buffer = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            let bytesRead = recv(fd, &buffer, buffer.count, 0)

            if bytesRead <= 0 {
                // Connection closed or error
                break
            }

            let data = Data(buffer[0..<bytesRead])
            dataHandler?(connectionId, data)
        }

        // Clean up
        lock.lock()
        connections.removeValue(forKey: connectionId)
        lock.unlock()

        _ = systemClose(fd)
        disconnectHandler?(connectionId)
    }
}

/// Global native socket server instance
nonisolated(unsafe) public var nativeSocketServer: NativeSocketServer?
private let socketServerLock = NSLock()

/// Start native socket server
@_cdecl("aro_native_socket_server_start")
public func aro_native_socket_server_start(_ port: Int32) -> Int32 {
    socketServerLock.lock()
    defer { socketServerLock.unlock() }

    // Create server if needed
    if nativeSocketServer == nil {
        nativeSocketServer = NativeSocketServer(port: Int(port))

        // Set up handlers for broadcast behavior
        nativeSocketServer?.onConnect { connectionId, remoteAddress in
            print("[Handle Client Connected] SocketConnection(id: \"\(connectionId)\", remoteAddress: \"\(remoteAddress)\")")
        }

        nativeSocketServer?.onData { connectionId, data in
            // Broadcast to all clients (including sender for chat-style apps)
            _ = nativeSocketServer?.broadcast(data: data)
            if let str = String(data: data, encoding: .utf8) {
                print("[Handle Data Received] Broadcast: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        nativeSocketServer?.onDisconnect { connectionId in
            print("[Handle Client Disconnected] \(connectionId)")
        }
    }

    return nativeSocketServer?.start() == true ? 0 : -1
}

/// Stop native socket server
@_cdecl("aro_native_socket_server_stop")
public func aro_native_socket_server_stop() {
    socketServerLock.lock()
    defer { socketServerLock.unlock() }

    nativeSocketServer?.stop()
    nativeSocketServer = nil
}

/// Send data to a connection
@_cdecl("aro_native_socket_send")
public func aro_native_socket_send(
    _ connectionId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let connId = connectionId.map({ String(cString: $0) }),
          let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return server?.send(data: sendData, to: connId) == true ? 0 : -1
}

/// Broadcast data to all connections
@_cdecl("aro_native_socket_broadcast")
public func aro_native_socket_broadcast(
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return Int32(server?.broadcast(data: sendData) ?? 0)
}

/// Broadcast data to all connections except sender
@_cdecl("aro_native_socket_broadcast_excluding")
public func aro_native_socket_broadcast_excluding(
    _ senderId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    guard let senderIdStr = senderId.map({ String(cString: $0) }),
          let dataPtr = data else { return -1 }

    let sendData = Data(bytes: dataPtr, count: length)

    socketServerLock.lock()
    let server = nativeSocketServer
    socketServerLock.unlock()

    return Int32(server?.broadcast(data: sendData, excluding: senderIdStr) ?? 0)
}

// MARK: - Native HTTP Server (BSD Sockets)

/// Request handler type for native HTTP server
public typealias NativeHTTPRequestHandler = (String, String, [String: String], Data?) -> (Int, [String: String], Data?)

/// Native HTTP Server using BSD sockets
/// This provides a working HTTP server for compiled binaries with WebSocket support
public final class NativeHTTPServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let lock = NSLock()
    private var requestHandler: NativeHTTPRequestHandler?

    /// WebSocket connection storage
    private var wsConnections: [String: Int32] = [:]
    private let wsLock = NSLock()

    /// WebSocket path to listen on
    private var wsPath: String = "/ws"

    /// Event bus for WebSocket events
    public var eventBus: EventBus?

    public let port: Int

    /// Number of active WebSocket connections
    public var wsConnectionCount: Int {
        wsLock.lock()
        defer { wsLock.unlock() }
        return wsConnections.count
    }

    public init(port: Int) {
        self.port = port
    }

    /// Configure WebSocket path
    public func setWebSocketPath(_ path: String) {
        wsPath = path
    }

    /// Set event bus for WebSocket events
    public func setEventBus(_ eventBus: EventBus) {
        self.eventBus = eventBus
    }

    deinit {
        stop()
    }

    /// Set request handler
    public func onRequest(_ handler: @escaping NativeHTTPRequestHandler) {
        requestHandler = handler
    }

    /// Wait for data to be available on the socket using select()
    /// Returns true if data is available, false on timeout or error
    private func waitForData(fd: Int32, timeoutMs: Int) -> Bool {
        var readfds = fd_set()
        withUnsafeMutablePointer(to: &readfds) { ptr in
            // Zero out the fd_set
            let rawPtr = UnsafeMutableRawPointer(ptr)
            memset(rawPtr, 0, MemoryLayout<fd_set>.size)
        }

        // Set the fd bit manually - FD_SET macro equivalent
        let fdIndex = Int(fd)
        let bitsPerInt = MemoryLayout<Int32>.size * 8
        let arrayIndex = fdIndex / bitsPerInt
        let bitIndex = fdIndex % bitsPerInt

        withUnsafeMutablePointer(to: &readfds) { ptr in
            let intPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int32.self)
            intPtr[arrayIndex] |= Int32(1 << bitIndex)
        }

        var timeout = timeval()
        timeout.tv_sec = timeoutMs / 1000
        #if os(Linux)
        timeout.tv_usec = Int(timeoutMs % 1000) * 1000
        #else
        timeout.tv_usec = Int32(timeoutMs % 1000) * 1000
        #endif

        let result = select(fd + 1, &readfds, nil, nil, &timeout)
        return result > 0
    }

    /// Start the server
    public func start() -> Bool {
        // Create socket
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            print("[NativeHTTPServer] Failed to create socket")
            return false
        }

        // Set SO_REUSEADDR
        var reuseAddr: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind to port
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            print("[NativeHTTPServer] Failed to bind to port \(port)")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeHTTPServer] Failed to listen")
            _ = systemClose(serverFd)
            serverFd = -1
            return false
        }

        isRunning = true
        print("HTTP Server started on port \(port)")

        // Start accept loop in background
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }

        return true
    }

    /// Stop the server
    public func stop() {
        isRunning = false

        // Close server socket
        if serverFd >= 0 {
            _ = systemClose(serverFd)
            serverFd = -1
        }

        print("[NativeHTTPServer] Stopped")
    }

    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverFd, sockaddrPtr, &addrLen)
                }
            }

            guard clientFd >= 0, isRunning else { continue }

            // Handle client in background
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleClient(fd: clientFd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var totalData = Data()

        // Read initial request data
        let bytesRead = recv(fd, &buffer, buffer.count, 0)

        guard bytesRead > 0 else {
            _ = systemClose(fd)
            return
        }

        totalData.append(contentsOf: buffer[0..<bytesRead])

        guard let requestString = String(data: totalData, encoding: .utf8) else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            _ = systemClose(fd)
            return
        }

        let method = String(parts[0])
        let path = String(parts[1])

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let name = String(headerParts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        // Check for WebSocket upgrade request
        if isWebSocketUpgrade(path: path, headers: headers) {
            if performWebSocketHandshake(fd: fd, headers: headers) {
                let connectionId = UUID().uuidString
                handleWebSocket(fd: fd, connectionId: connectionId)
            } else {
                sendResponse(fd: fd, statusCode: 400, body: "WebSocket handshake failed")
                _ = systemClose(fd)
            }
            return
        }

        // Find body using byte-level extraction based on Content-Length
        // This is more reliable than string-based parsing
        var body: Data? = nil

        // Find where body starts (after \r\n\r\n) in byte data
        let headerSeparator = Data("\r\n\r\n".utf8)
        if let separatorRange = totalData.range(of: headerSeparator) {
            let bodyStartIndex = separatorRange.upperBound

            // Check Content-Length and read remaining body if needed
            if let contentLengthStr = headers["Content-Length"] ?? headers["content-length"],
               let contentLength = Int(contentLengthStr), contentLength > 0 {

                let currentBodyLength = totalData.count - bodyStartIndex

                // Read more data if we don't have the full body yet
                var remainingToRead = contentLength - currentBodyLength
                while remainingToRead > 0 {
                    // Wait for data with select() before reading
                    // This is critical on Linux where TCP fragmentation may cause
                    // headers and body to arrive in separate packets
                    if !waitForData(fd: fd, timeoutMs: 5000) {
                        break // Timeout or error waiting for data
                    }

                    let bytesToRead = min(buffer.count, remainingToRead)
                    let additionalBytesRead = recv(fd, &buffer, bytesToRead, 0)
                    if additionalBytesRead <= 0 {
                        break // Connection closed or error
                    }
                    totalData.append(contentsOf: buffer[0..<additionalBytesRead])
                    remainingToRead -= additionalBytesRead
                }
            }

            // Extract body as raw bytes (not through string conversion)
            if totalData.count > bodyStartIndex {
                body = totalData.subdata(in: bodyStartIndex..<totalData.count)
            }
        }

        // Call request handler
        if let handler = requestHandler {
            let (statusCode, responseHeaders, responseBody) = handler(method, path, headers, body)
            sendResponse(fd: fd, statusCode: statusCode, headers: responseHeaders, bodyData: responseBody)
        } else {
            // Default response
            sendResponse(fd: fd, statusCode: 200, body: "{\"status\":\"ok\"}")
        }

        // Graceful socket close: signal end of transmission before closing
        // This prevents "Connection reset by peer" errors for some HTTP clients (like HTTP::Tiny)
        _ = shutdown(fd, Int32(SHUT_WR))
        Thread.sleep(forTimeInterval: 0.01) // Brief delay for client to read response
        _ = systemClose(fd)
    }

    private func sendResponse(fd: Int32, statusCode: Int, headers: [String: String] = [:], body: String) {
        sendResponse(fd: fd, statusCode: statusCode, headers: headers, bodyData: body.data(using: .utf8))
    }

    private func sendResponse(fd: Int32, statusCode: Int, headers: [String: String] = [:], bodyData: Data?) {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 201: statusText = "Created"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        var finalHeaders = headers
        if finalHeaders["Content-Type"] == nil {
            finalHeaders["Content-Type"] = "application/json"
        }
        if let body = bodyData {
            finalHeaders["Content-Length"] = String(body.count)
        }
        finalHeaders["Connection"] = "close"

        for (name, value) in finalHeaders {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\n"

        // Send headers
        let headerData = response.data(using: .utf8)!
        headerData.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, headerData.count, 0)
        }

        // Send body
        if let body = bodyData {
            body.withUnsafeBytes { buffer in
                _ = systemSend(fd, buffer.baseAddress!, body.count, 0)
            }
        }
    }

    // MARK: - WebSocket Support

    /// Check if request is a WebSocket upgrade request
    private func isWebSocketUpgrade(path: String, headers: [String: String]) -> Bool {
        guard path == wsPath || path.hasPrefix(wsPath + "?") else { return false }
        let upgrade = headers["Upgrade"]?.lowercased() ?? headers["upgrade"]?.lowercased()
        let connection = headers["Connection"]?.lowercased() ?? headers["connection"]?.lowercased()
        return upgrade == "websocket" && (connection?.contains("upgrade") ?? false)
    }

    /// Perform WebSocket handshake
    private func performWebSocketHandshake(fd: Int32, headers: [String: String]) -> Bool {
        guard let key = headers["Sec-WebSocket-Key"] ?? headers["sec-websocket-key"] else {
            return false
        }

        // WebSocket magic string
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic

        // SHA-1 hash and base64 encode
        guard let data = combined.data(using: .utf8),
              let hash = sha1(data) else {
            return false
        }

        let acceptKey = hash.base64EncodedString()

        // Build handshake response
        var response = "HTTP/1.1 101 Switching Protocols\r\n"
        response += "Upgrade: websocket\r\n"
        response += "Connection: Upgrade\r\n"
        response += "Sec-WebSocket-Accept: \(acceptKey)\r\n"
        response += "\r\n"

        // Send response
        guard let responseData = response.data(using: .utf8) else { return false }
        var sent = 0
        while sent < responseData.count {
            let result = responseData.withUnsafeBytes { buffer in
                systemSend(fd, buffer.baseAddress!.advanced(by: sent), responseData.count - sent, 0)
            }
            if result <= 0 { return false }
            sent += result
        }

        return true
    }

    /// SHA-1 hash implementation
    private func sha1(_ data: Data) -> Data? {
        #if os(macOS)
        var hash = [UInt8](repeating: 0, count: 20)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
        #elseif os(Linux)
        // Use Swift Crypto on Linux
        let digest = Insecure.SHA1.hash(data: data)
        return Data(digest)
        #else
        return nil
        #endif
    }

    /// Handle WebSocket connection
    private func handleWebSocket(fd: Int32, connectionId: String) {
        // Register connection
        wsLock.lock()
        wsConnections[connectionId] = fd
        wsLock.unlock()

        // Emit connect event
        eventBus?.publish(WebSocketConnectedEvent(
            connectionId: connectionId,
            path: wsPath,
            remoteAddress: "unknown"
        ))

        defer {
            // Cleanup on disconnect
            wsLock.lock()
            wsConnections.removeValue(forKey: connectionId)
            wsLock.unlock()

            // Emit disconnect event
            eventBus?.publish(WebSocketDisconnectedEvent(
                connectionId: connectionId,
                reason: "connection closed"
            ))

            _ = systemClose(fd)
        }

        // WebSocket frame reading loop
        var buffer = [UInt8](repeating: 0, count: 8192)
        while isRunning {
            // Wait for data with timeout
            if !waitForData(fd: fd, timeoutMs: 1000) {
                continue // Timeout, check if still running
            }

            let bytesRead = recv(fd, &buffer, buffer.count, 0)
            guard bytesRead > 0 else {
                break // Connection closed or error
            }

            // Parse WebSocket frame
            guard let frame = parseWebSocketFrame(Data(buffer[0..<bytesRead])) else {
                continue
            }

            switch frame.opcode {
            case 0x1: // Text frame
                if let text = String(data: frame.payload, encoding: .utf8) {
                    // Emit message event
                    eventBus?.publish(WebSocketMessageEvent(
                        connectionId: connectionId,
                        message: text
                    ))
                }

            case 0x8: // Close frame
                // Send close frame back
                sendWebSocketFrame(fd: fd, opcode: 0x8, payload: Data())
                return

            case 0x9: // Ping frame
                // Send pong
                sendWebSocketFrame(fd: fd, opcode: 0xA, payload: frame.payload)

            default:
                break
            }
        }
    }

    /// Parse a WebSocket frame
    private func parseWebSocketFrame(_ data: Data) -> (opcode: UInt8, payload: Data)? {
        guard data.count >= 2 else { return nil }

        let byte0 = data[0]
        let byte1 = data[1]

        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = UInt64(byte1 & 0x7F)
        var offset = 2

        // Extended payload length
        if payloadLen == 126 {
            guard data.count >= 4 else { return nil }
            payloadLen = UInt64(data[2]) << 8 | UInt64(data[3])
            offset = 4
        } else if payloadLen == 127 {
            guard data.count >= 10 else { return nil }
            payloadLen = 0
            for i in 0..<8 {
                payloadLen |= UInt64(data[2 + i]) << (56 - 8 * i)
            }
            offset = 10
        }

        // Read mask key if present
        var maskKey: [UInt8]? = nil
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = Array(data[offset..<offset + 4])
            offset += 4
        }

        // Extract payload
        guard data.count >= offset + Int(payloadLen) else { return nil }
        var payload = Data(data[offset..<offset + Int(payloadLen)])

        // Unmask payload
        if let mask = maskKey {
            for i in 0..<payload.count {
                payload[i] ^= mask[i % 4]
            }
        }

        return (opcode, payload)
    }

    /// Send a WebSocket frame
    private func sendWebSocketFrame(fd: Int32, opcode: UInt8, payload: Data) {
        var frame = Data()

        // First byte: FIN + opcode
        frame.append(0x80 | opcode)

        // Payload length (no masking for server-to-client)
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((payload.count >> (8 * i)) & 0xFF))
            }
        }

        // Payload
        frame.append(payload)

        // Send
        frame.withUnsafeBytes { buffer in
            _ = systemSend(fd, buffer.baseAddress!, frame.count, 0)
        }
    }

    /// Broadcast a message to all WebSocket connections
    public func broadcastWebSocket(message: String) -> Int {
        guard let payload = message.data(using: .utf8) else { return 0 }

        wsLock.lock()
        let connections = wsConnections
        wsLock.unlock()

        var sentCount = 0
        for (_, fd) in connections {
            sendWebSocketFrame(fd: fd, opcode: 0x1, payload: payload)
            sentCount += 1
        }

        return sentCount
    }
}

/// Global native HTTP server instance
nonisolated(unsafe) public var nativeHTTPServer: NativeHTTPServer?
private let httpServerLock = NSLock()

// MARK: - JSON Conversion Helpers

/// Unwrap AnySendable for JSON serialization (uses get<T>() to access private value)
/// If the value is a JSON string, parse it back to an object
private func unwrapAnySendableForJSON(_ anySendable: AnySendable) -> Any {
    // Try each concrete type using the public get<T>() method
    if let str: String = anySendable.get() {
        // Check if the string is JSON - if so, parse it
        if str.hasPrefix("{") || str.hasPrefix("[") {
            if let jsonData = str.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) {
                return parsed
            }
        }
        return str
    }
    if let int: Int = anySendable.get() {
        return int
    }
    if let double: Double = anySendable.get() {
        return double
    }
    if let bool: Bool = anySendable.get() {
        return bool
    }
    if let dict: [String: any Sendable] = anySendable.get() {
        var result: [String: Any] = [:]
        for (k, v) in dict {
            result[k] = unwrapSendableForJSON(v)
        }
        return result
    }
    if let array: [any Sendable] = anySendable.get() {
        return array.map { unwrapSendableForJSON($0) }
    }
    // Fallback for unknown types
    return "{}"
}

/// Unwrap any Sendable value for JSON serialization
private func unwrapSendableForJSON(_ value: any Sendable) -> Any {
    switch value {
    case let str as String:
        return str
    case let int as Int:
        return int
    case let double as Double:
        return double
    case let bool as Bool:
        return bool
    case let dict as [String: any Sendable]:
        var result: [String: Any] = [:]
        for (k, v) in dict {
            result[k] = unwrapSendableForJSON(v)
        }
        return result
    case let array as [any Sendable]:
        return array.map { unwrapSendableForJSON($0) }
    case let anySendable as AnySendable:
        return unwrapAnySendableForJSON(anySendable)
    default:
        return String(describing: value)
    }
}

/// Convert Any (from JSON) to Sendable
private func convertAnyToSendable(_ value: Any) -> any Sendable {
    switch value {
    case let str as String:
        return str
    case let int as Int:
        return int
    case let double as Double:
        return double
    case let bool as Bool:
        return bool
    case let dict as [String: Any]:
        var result: [String: any Sendable] = [:]
        for (k, v) in dict {
            result[k] = convertAnyToSendable(v)
        }
        return result
    case let array as [Any]:
        return array.map { convertAnyToSendable($0) }
    case is NSNull:
        return "" // Represent null as empty string
    default:
        return String(describing: value)
    }
}

/// Registered feature set handlers for HTTP routing
/// Maps operationId to a function that executes the feature set
nonisolated(unsafe) public var httpRouteHandlers: [String: (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?] = [:]

/// Route registry for matching paths to operationIds
nonisolated(unsafe) public var httpRoutes: [(method: String, path: String, operationId: String)] = []

/// Response content type registry for operationIds (extracted from OpenAPI spec)
nonisolated(unsafe) public var httpResponseContentTypes: [String: String] = [:]

/// Global storage for embedded OpenAPI spec (JSON string, set at compile time)
nonisolated(unsafe) public var embeddedOpenAPISpec: String? = nil

/// Global storage for embedded templates (JSON dictionary: path -> content, set at compile time)
nonisolated(unsafe) public var embeddedTemplates: [String: String]? = nil

/// Set the embedded OpenAPI spec (called from generated main)
@_cdecl("aro_set_embedded_openapi")
public func aro_set_embedded_openapi(_ specPtr: UnsafePointer<CChar>?) {
    guard let ptr = specPtr else { return }
    embeddedOpenAPISpec = String(cString: ptr)
}

/// Set the embedded templates (called from generated main) - ARO-0050
@_cdecl("aro_set_embedded_templates")
public func aro_set_embedded_templates(_ jsonPtr: UnsafePointer<CChar>?) {
    guard let ptr = jsonPtr else { return }
    let jsonString = String(cString: ptr)

    // Parse the JSON dictionary
    guard let data = jsonString.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return
    }
    embeddedTemplates = dict
}

/// Register a feature set handler for HTTP routing
@_cdecl("aro_http_register_route")
public func aro_http_register_route(
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ operationId: UnsafePointer<CChar>?
) {
    guard let methodStr = method.map({ String(cString: $0) }),
          let pathStr = path.map({ String(cString: $0) }),
          let opId = operationId.map({ String(cString: $0) }) else { return }

    httpServerLock.lock()
    httpRoutes.append((method: methodStr, path: pathStr, operationId: opId))
    httpServerLock.unlock()
}

/// Start native HTTP server
@_cdecl("aro_native_http_server_start")
public func aro_native_http_server_start(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    httpServerLock.lock()
    defer { httpServerLock.unlock() }

    // Create server if needed
    if nativeHTTPServer == nil {
        nativeHTTPServer = NativeHTTPServer(port: Int(port))

        // Set eventBus - use context's eventBus if available, otherwise use shared
        let eventBus: EventBus
        if let ptr = contextPtr {
            let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()
            eventBus = ctxHandle.context.eventBus ?? EventBus.shared
        } else {
            eventBus = EventBus.shared
        }
        nativeHTTPServer?.setEventBus(eventBus)

        // Subscribe to WebSocket broadcast events
        eventBus.subscribe(to: WebSocketBroadcastRequestedEvent.self) { event in
            _ = nativeHTTPServer?.broadcastWebSocket(message: event.message)
        }

        // Set up request handler
        nativeHTTPServer?.onRequest { method, path, headers, body in
            // Parse path and query string
            let pathComponents = path.split(separator: "?", maxSplits: 1)
            let pathWithoutQuery = String(pathComponents[0])
            var queryParams: [String: String] = [:]
            if pathComponents.count > 1 {
                let queryString = String(pathComponents[1])
                for pair in queryString.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    if kv.count == 2 {
                        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                        let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                        queryParams[key] = value
                    } else if kv.count == 1 {
                        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                        queryParams[key] = ""
                    }
                }
            }

            // Match route to operationId (using path without query string)
            // Supports OpenAPI path parameters like /users/{id}
            var matchedOperationId: String? = nil
            var pathParams: [String: String] = [:]

            for route in httpRoutes {
                if route.method == method {
                    if let params = matchPath(pattern: route.path, actual: pathWithoutQuery) {
                        matchedOperationId = route.operationId
                        pathParams = params
                        break
                    }
                }
            }

            // Helper function to extract response from context and serialize appropriately
            func getContextResponse(_ ctxPtr: UnsafeMutableRawPointer?, operationId: String?, requestPath: String = "") -> (Int, [String: String], Data?) {
                guard let ptr = ctxPtr else {
                    return (500, ["Content-Type": "application/json"], "{\"error\":\"No context\"}".data(using: .utf8))
                }
                let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

                // Check for execution errors first (e.g., from Accept action validation failures)
                if let error = ctxHandle.context.getExecutionError() {
                    let errorMsg = error.localizedDescription

                    // Check for template not found errors - return 404
                    // In binary mode, errors are wrapped as ActionError.runtimeError with the message
                    if let templateError = error as? TemplateError {
                        if case .notFound = templateError {
                            let msg = templateError.errorDescription ?? "Template not found"
                            let errorJson = "{\"error\":\"Not Found\",\"message\":\"\(msg.replacingOccurrences(of: "\"", with: "\\\""))\"}".data(using: .utf8)
                            return (404, ["Content-Type": "application/json"], errorJson)
                        }
                    }
                    // Check for template not found pattern in error message (binary mode)
                    else if errorMsg.contains("Template not found:") || errorMsg.contains("notFound(path:") {
                        let escapedMsg = errorMsg.replacingOccurrences(of: "\"", with: "\\\"")
                        let errorJson = "{\"error\":\"Not Found\",\"message\":\"\(escapedMsg)\"}".data(using: .utf8)
                        return (404, ["Content-Type": "application/json"], errorJson)
                    }

                    let escapedMsg = errorMsg.replacingOccurrences(of: "\"", with: "\\\"")
                    let errorJson = "{\"error\":\"\(escapedMsg)\"}".data(using: .utf8)
                    return (500, ["Content-Type": "application/json"], errorJson)
                }

                if let response = ctxHandle.context.getResponse() {
                    // Convert Response.data to JSON, returning just the data portion
                    let statusLower = response.status.lowercased()
                    let statusCode = statusLower == "ok" ? 200 :
                                   statusLower == "created" ? 201 :
                                   statusLower == "nocontent" ? 204 :
                                   statusLower == "error" ? 400 : 200

                    // For 204 No Content, return empty body
                    if statusCode == 204 {
                        return (204, [:], nil)
                    }

                    // Get expected content type from OpenAPI spec
                    let expectedContentType = operationId.flatMap { httpResponseContentTypes[$0] }

                    // Check for single-value response that should be returned as-is
                    if response.data.count == 1, let (_, anySendable) = response.data.first {
                        if let str: String = anySendable.get() {
                            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)

                            // Priority 1: Detect MIME type from request path file extension
                            let lowercasePath = requestPath.lowercased()
                            if lowercasePath.hasSuffix(".css") {
                                return (statusCode, ["Content-Type": "text/css; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".js") {
                                return (statusCode, ["Content-Type": "text/javascript; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".json") {
                                return (statusCode, ["Content-Type": "application/json; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".html") || lowercasePath.hasSuffix(".htm") {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".xml") {
                                return (statusCode, ["Content-Type": "application/xml; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".txt") {
                                return (statusCode, ["Content-Type": "text/plain; charset=utf-8"], str.data(using: .utf8))
                            } else if lowercasePath.hasSuffix(".svg") {
                                return (statusCode, ["Content-Type": "image/svg+xml"], str.data(using: .utf8))
                            }

                            // Priority 2: If OpenAPI says text/html, return as HTML
                            if expectedContentType == "text/html" {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Priority 3: Content-based detection (fallback)
                            // Detect HTML content
                            if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<!doctype") ||
                               trimmed.hasPrefix("<html") || trimmed.hasPrefix("<HTML") {
                                return (statusCode, ["Content-Type": "text/html; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Detect JavaScript content
                            if trimmed.hasPrefix("var ") || trimmed.hasPrefix("let ") ||
                               trimmed.hasPrefix("const ") || trimmed.hasPrefix("function ") ||
                               trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") ||
                               trimmed.hasPrefix("'use strict'") || trimmed.hasPrefix("\"use strict\"") ||
                               trimmed.hasPrefix("(function") || trimmed.hasPrefix("import ") ||
                               trimmed.hasPrefix("export ") {
                                return (statusCode, ["Content-Type": "text/javascript; charset=utf-8"], str.data(using: .utf8))
                            }

                            // Detect CSS content
                            if !trimmed.hasPrefix("{") && !trimmed.hasPrefix("<") {
                                let cssPattern = try? NSRegularExpression(
                                    pattern: "^(@|\\*|[a-zA-Z][a-zA-Z0-9-]*|\\.[a-zA-Z]|#[a-zA-Z])[^{]*\\{",
                                    options: []
                                )
                                if let match = cssPattern?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                                   match.range.location != NSNotFound {
                                    return (statusCode, ["Content-Type": "text/css; charset=utf-8"], str.data(using: .utf8))
                                }
                            }
                        }
                    }

                    // Build JSON from response data
                    var jsonDict: [String: Any] = [:]
                    for (key, anySendable) in response.data {
                        jsonDict[key] = unwrapAnySendableForJSON(anySendable)
                    }

                    // If no data, include status as fallback
                    if jsonDict.isEmpty {
                        jsonDict["status"] = response.status
                    }

                    if let jsonData = try? JSONSerialization.data(withJSONObject: jsonDict, options: [.sortedKeys]) {
                        return (statusCode, ["Content-Type": "application/json"], jsonData)
                    }
                }
                return (200, ["Content-Type": "application/json"], "{\"status\":\"ok\"}".data(using: .utf8))
            }

            // Helper to bind request data to context
            func bindRequestToContext(_ ctxPtr: UnsafeMutableRawPointer?, body: Data?, headers: [String: String], path: String, queryParams: [String: String], pathParams: [String: String]) {
                guard let ptr = ctxPtr else { return }
                let ctxHandle = Unmanaged<AROCContextHandle>.fromOpaque(ptr).takeUnretainedValue()

                // Bind request as a dictionary with body, headers, etc.
                var requestDict: [String: any Sendable] = [:]

                // Parse body as JSON if possible, otherwise as string
                if let bodyData = body {
                    if let json = try? JSONSerialization.jsonObject(with: bodyData),
                       let dict = json as? [String: Any] {
                        // Body is JSON - convert to Sendable dict
                        var bodyDict: [String: any Sendable] = [:]
                        for (k, v) in dict {
                            bodyDict[k] = convertAnyToSendable(v)
                        }
                        requestDict["body"] = bodyDict
                        // Also bind body directly for <Extract> the <x> from the <body: field>.
                        ctxHandle.context.bind("body", value: bodyDict)
                    } else if let bodyStr = String(data: bodyData, encoding: .utf8) {
                        requestDict["body"] = bodyStr
                        ctxHandle.context.bind("body", value: bodyStr)
                    }
                }

                requestDict["path"] = path
                requestDict["headers"] = headers

                ctxHandle.context.bind("request", value: requestDict)

                // Bind query parameters for <Extract> the <x> from the <queryParameters: y>
                ctxHandle.context.bind("queryParameters", value: queryParams)

                // Bind path parameters for <Extract> the <id> from the <pathParameters: id>
                ctxHandle.context.bind("pathParameters", value: pathParams)
            }

            // If route matched, try to invoke the feature set
            if let opId = matchedOperationId {
                // Create a fresh context for this request if none provided
                let requestContext: UnsafeMutableRawPointer?
                if let providedCtx = contextPtr {
                    requestContext = providedCtx
                } else {
                    // Create new context via aro_context_create using global runtime
                    requestContext = aro_context_create(globalRuntimePtr)
                }

                // Bind request data to context before invoking handler
                bindRequestToContext(requestContext, body: body, headers: headers, path: pathWithoutQuery, queryParams: queryParams, pathParams: pathParams)

                // First check for registered handler
                if let handler = httpRouteHandlers[opId] {
                    _ = handler(requestContext)
                    let response = getContextResponse(requestContext, operationId: opId, requestPath: pathWithoutQuery)
                    // Clean up if we created the context
                    if contextPtr == nil, let ctx = requestContext {
                        aro_context_destroy(ctx)
                    }
                    return response
                }

                // Try to find the compiled feature set function via dlsym
                // Must match LLVMCodeGenerator.mangleFeatureSetName()
                let functionName = "aro_fs_" + opId
                    .replacingOccurrences(of: "-", with: "_")
                    .replacingOccurrences(of: " ", with: "_")
                    .lowercased()
                if let handle = dlopen(nil, RTLD_NOW),
                   let sym = dlsym(handle, functionName) {
                    typealias FSFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                    let function = unsafeBitCast(sym, to: FSFunction.self)
                    _ = function(requestContext)
                    let response = getContextResponse(requestContext, operationId: opId, requestPath: pathWithoutQuery)
                    // Clean up if we created the context
                    if contextPtr == nil, let ctx = requestContext {
                        aro_context_destroy(ctx)
                    }
                    return response
                }

                // Clean up if we created the context but didn't find handler
                if contextPtr == nil, let ctx = requestContext {
                    aro_context_destroy(ctx)
                }

                // Route matched but no handler - return placeholder success
                return (200, ["Content-Type": "application/json"], "{\"status\":\"ok\"}".data(using: .utf8))
            }

            // Default: Not found
            return (404, ["Content-Type": "application/json"], "{\"error\":\"Not Found\"}".data(using: .utf8))
        }
    }

    return nativeHTTPServer?.start() == true ? 0 : -1
}

/// Start native HTTP server with OpenAPI spec (embedded or from file)
/// If port is 0, reads port from OpenAPI spec's server URL
@_cdecl("aro_native_http_server_start_with_openapi")
public func aro_native_http_server_start_with_openapi(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    httpServerLock.lock()

    var finalPort = port
    var openapiContent: String? = nil

    // Priority 1: Use embedded spec if available (compiled into binary)
    if let embedded = embeddedOpenAPISpec {
        openapiContent = embedded
    }
    // Priority 2: Fall back to file-based loading from binary's directory
    else {
        let executablePath = CommandLine.arguments[0]
        let binaryDir = (executablePath as NSString).deletingLastPathComponent
        let openapiPath = binaryDir + "/openapi.yaml"
        openapiContent = try? String(contentsOfFile: openapiPath, encoding: .utf8)
    }

    // Parse routes and extract port from the spec
    if let content = openapiContent {
        parseOpenAPIRoutes(content)

        if finalPort == 0 {
            finalPort = Int32(extractPortFromOpenAPI(content))
        }
    }

    // Default to 8080 if no port found
    if finalPort == 0 {
        finalPort = 8080
    }

    httpServerLock.unlock()

    return aro_native_http_server_start(finalPort, contextPtr)
}

/// Extract port from OpenAPI spec's server URL (auto-detects YAML or JSON)
private func extractPortFromOpenAPI(_ content: String) -> Int {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
        return extractPortFromOpenAPIJSON(content)
    } else {
        return extractPortFromOpenAPIYAML(content)
    }
}

/// Extract port from OpenAPI YAML spec's server URL
private func extractPortFromOpenAPIYAML(_ yaml: String) -> Int {
    let lines = yaml.components(separatedBy: "\n")

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Look for "url: http://localhost:PORT" pattern
        if trimmed.hasPrefix("- url:") || trimmed.hasPrefix("url:") {
            let urlPart = trimmed.replacingOccurrences(of: "- url:", with: "")
                .replacingOccurrences(of: "url:", with: "")
                .trimmingCharacters(in: .whitespaces)

            if let port = extractPortFromURL(urlPart) {
                return port
            }
        }
    }

    return 0
}

/// Extract port from OpenAPI JSON spec's server URL
private func extractPortFromOpenAPIJSON(_ json: String) -> Int {
    guard let data = json.data(using: .utf8),
          let spec = try? JSONDecoder().decode(OpenAPISpec.self, from: data),
          let servers = spec.servers,
          let firstServer = servers.first else {
        return 0
    }

    return extractPortFromURL(firstServer.url) ?? 0
}

/// Extract port number from a URL string
private func extractPortFromURL(_ urlString: String) -> Int? {
    // Extract port from URL like "http://localhost:8000"
    if let colonRange = urlString.range(of: "://") {
        let afterScheme = String(urlString[colonRange.upperBound...])
        // Look for :PORT at the end
        if let lastColon = afterScheme.lastIndex(of: ":") {
            let portString = String(afterScheme[afterScheme.index(after: lastColon)...])
                .components(separatedBy: CharacterSet(charactersIn: "/")).first ?? ""
            return Int(portString)
        }
    }
    return nil
}

/// Match an actual path against an OpenAPI pattern with path parameters
/// Returns extracted path parameters if match succeeds, nil if no match
/// Example: pattern="/users/{id}", actual="/users/123" returns ["id": "123"]
private func matchPath(pattern: String, actual: String) -> [String: String]? {
    let patternParts = pattern.split(separator: "/", omittingEmptySubsequences: false)
    let actualParts = actual.split(separator: "/", omittingEmptySubsequences: false)

    // Must have same number of path segments
    guard patternParts.count == actualParts.count else { return nil }

    var params: [String: String] = [:]

    for (patternPart, actualPart) in zip(patternParts, actualParts) {
        let patternStr = String(patternPart)
        let actualStr = String(actualPart)

        // Check if this is a path parameter like {id}
        if patternStr.hasPrefix("{") && patternStr.hasSuffix("}") {
            // Extract parameter name (remove braces)
            let paramName = String(patternStr.dropFirst().dropLast())
            params[paramName] = actualStr
        } else {
            // Must match exactly
            if patternStr != actualStr {
                return nil
            }
        }
    }

    return params
}

/// Simple OpenAPI route parser (auto-detects YAML or JSON)
private func parseOpenAPIRoutes(_ content: String) {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
        parseOpenAPIRoutesJSON(content)
    } else {
        parseOpenAPIRoutesYAML(content)
    }
}

/// Parse routes from OpenAPI JSON spec
private func parseOpenAPIRoutesJSON(_ json: String) {
    guard let data = json.data(using: .utf8),
          let spec = try? JSONDecoder().decode(OpenAPISpec.self, from: data) else {
        return
    }

    for (path, pathItem) in spec.paths {
        for (method, operation) in pathItem.allOperations {
            if let opId = operation.operationId {
                httpRoutes.append((method: method.uppercased(), path: path, operationId: opId))

                // Extract response content type from 200/201 response
                if let response = operation.responses["200"] ?? operation.responses["201"],
                   let content = response.content,
                   let firstContentType = content.keys.first {
                    httpResponseContentTypes[opId] = firstContentType
                }
            }
        }
    }
}

/// Parse routes from OpenAPI YAML spec
private func parseOpenAPIRoutesYAML(_ yaml: String) {
    let lines = yaml.components(separatedBy: "\n")
    var currentPath: String? = nil
    var currentMethod: String? = nil
    var currentOperationId: String? = nil
    var inResponses = false
    var in200Response = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Check for path (reset state when entering new path)
        if line.hasPrefix("  /") && line.contains(":") {
            let pathPart = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = pathPart.firstIndex(of: ":") {
                currentPath = String(pathPart[..<colonIndex])
                currentMethod = nil
                currentOperationId = nil
                inResponses = false
                in200Response = false
            }
        }
        // Check for method
        else if trimmed.hasPrefix("get:") || trimmed.hasPrefix("post:") ||
                trimmed.hasPrefix("put:") || trimmed.hasPrefix("delete:") ||
                trimmed.hasPrefix("patch:") {
            currentMethod = String(trimmed.dropLast()) // Remove ":"
            currentOperationId = nil
            inResponses = false
            in200Response = false
        }
        // Check for operationId
        else if trimmed.hasPrefix("operationId:") {
            let opId = trimmed.replacingOccurrences(of: "operationId:", with: "")
                .trimmingCharacters(in: .whitespaces)
            currentOperationId = opId

            if let path = currentPath, let method = currentMethod {
                httpRoutes.append((method: method.uppercased(), path: path, operationId: opId))
            }
        }
        // Track responses section
        else if trimmed.hasPrefix("responses:") {
            inResponses = true
            in200Response = false
        }
        // Track 200/201 response
        else if inResponses && (trimmed.hasPrefix("'200':") || trimmed.hasPrefix("\"200\":") ||
                                trimmed.hasPrefix("'201':") || trimmed.hasPrefix("\"201\":")) {
            in200Response = true
        }
        // Look for content type in response content section
        else if in200Response && trimmed.hasPrefix("content:") {
            // Next non-empty line with proper indentation should be the content type
            continue
        }
        // Capture content type (e.g., "text/html:", "application/json:")
        else if in200Response && !trimmed.isEmpty && trimmed.hasSuffix(":") &&
                (trimmed.contains("/")) {
            let contentType = String(trimmed.dropLast()) // Remove ":"
            if let opId = currentOperationId {
                httpResponseContentTypes[opId] = contentType
            }
            in200Response = false // Done with this response
        }
    }
}

/// Stop native HTTP server
@_cdecl("aro_native_http_server_stop")
public func aro_native_http_server_stop() {
    httpServerLock.lock()
    defer { httpServerLock.unlock() }

    nativeHTTPServer?.stop()
    nativeHTTPServer = nil
}

// MARK: - Socket Bridge (Legacy API)

/// Socket handle
final class SocketHandle: @unchecked Sendable {
    var isServer: Bool
    var host: String = ""
    var port: Int = 0
    var isConnected: Bool = false

    init(isServer: Bool) {
        self.isServer = isServer
    }
}

/// Create a TCP server socket
@_cdecl("aro_socket_server_create")
public func aro_socket_server_create(
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> UnsafeMutableRawPointer? {
    let handle = SocketHandle(isServer: true)
    handle.host = host.map { String(cString: $0) } ?? "127.0.0.1"
    handle.port = Int(port)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Create a TCP client socket
@_cdecl("aro_socket_client_create")
public func aro_socket_client_create() -> UnsafeMutableRawPointer? {
    let handle = SocketHandle(isServer: false)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Connect client to server
@_cdecl("aro_socket_connect")
public func aro_socket_connect(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    guard let ptr = socketPtr,
          let hostStr = host.map({ String(cString: $0) }) else { return -1 }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.host = hostStr
    handle.port = Int(port)
    return 0
}

/// Start listening (server) - now uses native server
@_cdecl("aro_socket_listen")
public func aro_socket_listen(_ socketPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = socketPtr else { return -1 }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    guard handle.isServer else { return -1 }
    return aro_native_socket_server_start(Int32(handle.port))
}

/// Send data on socket
@_cdecl("aro_socket_send")
public func aro_socket_send(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int {
    guard socketPtr != nil, data != nil else { return -1 }
    return length
}

/// Receive data from socket
@_cdecl("aro_socket_recv")
public func aro_socket_recv(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ maxLength: Int
) -> Int {
    guard socketPtr != nil, buffer != nil else { return -1 }
    return 0
}

/// Close socket
@_cdecl("aro_socket_close")
public func aro_socket_close(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }
    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.isConnected = false
}

/// Destroy socket
@_cdecl("aro_socket_destroy")
public func aro_socket_destroy(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }
    Unmanaged<SocketHandle>.fromOpaque(ptr).release()
}

#else  // os(Windows)

// ============================================================
// Windows Stubs
// ============================================================
// These stub functions allow code to compile on Windows even though
// the full native implementations are not yet available.

// MARK: - File Watcher Stubs (Windows)

/// Create a file watcher (Windows stub - not yet implemented)
@_cdecl("aro_file_watcher_create")
public func aro_file_watcher_create(_ path: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    print("[FileMonitor] File watching not yet supported on Windows")
    return nil
}

/// Start watching for file changes (Windows stub)
@_cdecl("aro_file_watcher_start")
public func aro_file_watcher_start(_ watcherPtr: UnsafeMutableRawPointer?) -> Int32 {
    return -1  // Not supported
}

/// Stop watching (Windows stub)
@_cdecl("aro_file_watcher_stop")
public func aro_file_watcher_stop(_ watcherPtr: UnsafeMutableRawPointer?) {
    // No-op on Windows
}

/// Destroy file watcher (Windows stub)
@_cdecl("aro_file_watcher_destroy")
public func aro_file_watcher_destroy(_ watcherPtr: UnsafeMutableRawPointer?) {
    // No-op on Windows
}

// MARK: - Native Socket Server Stubs (Windows)

/// Start native socket server (Windows stub)
@_cdecl("aro_native_socket_server_start")
public func aro_native_socket_server_start(_ port: Int32) -> Int32 {
    print("[NativeSocketServer] Socket server not yet supported on Windows")
    return -1
}

/// Stop native socket server (Windows stub)
@_cdecl("aro_native_socket_server_stop")
public func aro_native_socket_server_stop() {
    // No-op on Windows
}

/// Send data to a connection (Windows stub)
@_cdecl("aro_native_socket_send")
public func aro_native_socket_send(
    _ connectionId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

/// Broadcast data to all connections (Windows stub)
@_cdecl("aro_native_socket_broadcast")
public func aro_native_socket_broadcast(
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

/// Broadcast data to all connections except sender (Windows stub)
@_cdecl("aro_native_socket_broadcast_excluding")
public func aro_native_socket_broadcast_excluding(
    _ senderId: UnsafePointer<CChar>?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int32 {
    return -1  // Not supported
}

// MARK: - Native HTTP Server Stubs (Windows)

/// Start native HTTP server (Windows stub)
@_cdecl("aro_native_http_server_start")
public func aro_native_http_server_start(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    print("[NativeHTTPServer] HTTP server not yet supported on Windows")
    return -1
}

/// Start native HTTP server with OpenAPI spec (Windows stub)
@_cdecl("aro_native_http_server_start_with_openapi")
public func aro_native_http_server_start_with_openapi(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    print("[NativeHTTPServer] HTTP server not yet supported on Windows")
    return -1
}

/// Stop native HTTP server (Windows stub)
@_cdecl("aro_native_http_server_stop")
public func aro_native_http_server_stop() {
    // No-op on Windows
}

/// Register a route handler (Windows stub)
@_cdecl("aro_http_register_route")
public func aro_http_register_route(
    _ method: UnsafePointer<CChar>?,
    _ path: UnsafePointer<CChar>?,
    _ operationId: UnsafePointer<CChar>?
) {
    // No-op on Windows
}

/// Set the embedded OpenAPI spec (Windows stub)
@_cdecl("aro_set_embedded_openapi")
public func aro_set_embedded_openapi(_ specPtr: UnsafePointer<CChar>?) {
    // No-op on Windows
}

/// Set the embedded templates (Windows stub) - ARO-0050
@_cdecl("aro_set_embedded_templates")
public func aro_set_embedded_templates(_ jsonPtr: UnsafePointer<CChar>?) {
    // No-op on Windows
}

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

// MARK: - File System Stubs (Windows)
// Note: Basic file operations use Foundation and should work on Windows.
// These stubs are for API consistency.

/// Read a file (Windows - uses Foundation)
@_cdecl("aro_file_read")
public func aro_file_read(
    _ path: UnsafePointer<CChar>?,
    _ outLength: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<CChar>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let content = try String(contentsOfFile: pathStr, encoding: .utf8)
        outLength?.pointee = content.utf8.count
        return strdup(content)
    } catch {
        return nil
    }
}

/// Write a file (Windows - uses Foundation)
@_cdecl("aro_file_write")
public func aro_file_write(
    _ path: UnsafePointer<CChar>?,
    _ content: UnsafePointer<CChar>?
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }),
          let contentStr = content.map({ String(cString: $0) }) else { return -1 }

    do {
        try contentStr.write(toFile: pathStr, atomically: true, encoding: .utf8)
        return 0
    } catch {
        return -1
    }
}

/// Check if file exists (Windows - uses Foundation)
@_cdecl("aro_file_exists")
public func aro_file_exists(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return 0 }
    return FileManager.default.fileExists(atPath: pathStr) ? 1 : 0
}

/// Delete a file (Windows - uses Foundation)
@_cdecl("aro_file_delete")
public func aro_file_delete(_ path: UnsafePointer<CChar>?) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.removeItem(atPath: pathStr)
        return 0
    } catch {
        return -1
    }
}

/// Create a directory (Windows - uses Foundation)
@_cdecl("aro_directory_create")
public func aro_directory_create(
    _ path: UnsafePointer<CChar>?,
    _ recursive: Int32
) -> Int32 {
    guard let pathStr = path.map({ String(cString: $0) }) else { return -1 }

    do {
        try FileManager.default.createDirectory(
            atPath: pathStr,
            withIntermediateDirectories: recursive != 0,
            attributes: nil
        )
        return 0
    } catch {
        return -1
    }
}

/// List directory contents (Windows - uses Foundation)
@_cdecl("aro_directory_list")
public func aro_directory_list(
    _ path: UnsafePointer<CChar>?,
    _ outCount: UnsafeMutablePointer<Int>?
) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard let pathStr = path.map({ String(cString: $0) }) else { return nil }

    do {
        let entries = try FileManager.default.contentsOfDirectory(atPath: pathStr)
        outCount?.pointee = entries.count

        let result = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: entries.count)
        for (i, entry) in entries.enumerated() {
            result[i] = strdup(entry)
        }
        return result
    } catch {
        return nil
    }
}

// MARK: - Socket Stubs (Windows)

/// Create a TCP server socket (Windows stub)
@_cdecl("aro_socket_server_create")
public func aro_socket_server_create(
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> UnsafeMutableRawPointer? {
    return nil
}

/// Create a TCP client socket (Windows stub)
@_cdecl("aro_socket_client_create")
public func aro_socket_client_create() -> UnsafeMutableRawPointer? {
    return nil
}

/// Connect client to server (Windows stub)
@_cdecl("aro_socket_connect")
public func aro_socket_connect(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ host: UnsafePointer<CChar>?,
    _ port: Int32
) -> Int32 {
    return -1
}

/// Start listening (Windows stub)
@_cdecl("aro_socket_listen")
public func aro_socket_listen(_ socketPtr: UnsafeMutableRawPointer?) -> Int32 {
    return -1
}

/// Send data on socket (Windows stub)
@_cdecl("aro_socket_send")
public func aro_socket_send(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int {
    return -1
}

/// Receive data from socket (Windows stub)
@_cdecl("aro_socket_recv")
public func aro_socket_recv(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ maxLength: Int
) -> Int {
    return -1
}

/// Close socket (Windows stub)
@_cdecl("aro_socket_close")
public func aro_socket_close(_ socketPtr: UnsafeMutableRawPointer?) {
    // No-op
}

/// Destroy socket (Windows stub)
@_cdecl("aro_socket_destroy")
public func aro_socket_destroy(_ socketPtr: UnsafeMutableRawPointer?) {
    // No-op
}

#endif  // !os(Windows)
