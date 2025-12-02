// ============================================================
// ServiceBridge.swift
// AROCRuntime - C-callable Service Interface
// ============================================================

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AROParser
import ARORuntime

#if os(macOS)
import CoreServices
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
    let hostStr = host.map { String(cString: $0) } ?? "127.0.0.1"

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

    let handle = Unmanaged<HTTPServerHandle>.fromOpaque(ptr).takeUnretainedValue()

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

        // Determine event type
        let eventType: String
        if (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
            eventType = "Created"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
            eventType = "Deleted"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                  (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0 {
            eventType = "Modified"
        } else if (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
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

// MARK: - Socket Bridge

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
/// - Parameters:
///   - host: Host to bind (C string)
///   - port: Port number
/// - Returns: Socket handle
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
/// - Returns: Socket handle
@_cdecl("aro_socket_client_create")
public func aro_socket_client_create() -> UnsafeMutableRawPointer? {
    let handle = SocketHandle(isServer: false)
    return UnsafeMutableRawPointer(Unmanaged.passRetained(handle).toOpaque())
}

/// Connect client to server
/// - Parameters:
///   - socketPtr: Socket handle
///   - host: Server host (C string)
///   - port: Server port
/// - Returns: 0 on success
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

    // Actual connection would use NIO
    // This is a simplified bridge

    return 0
}

/// Start listening (server)
/// - Parameter socketPtr: Socket handle
/// - Returns: 0 on success
@_cdecl("aro_socket_listen")
public func aro_socket_listen(_ socketPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = socketPtr else { return -1 }

    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    guard handle.isServer else { return -1 }

    // Actual listening would use NIO
    return 0
}

/// Send data on socket
/// - Parameters:
///   - socketPtr: Socket handle
///   - data: Data to send
///   - length: Data length
/// - Returns: Bytes sent or -1 on error
@_cdecl("aro_socket_send")
public func aro_socket_send(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ length: Int
) -> Int {
    guard socketPtr != nil,
          data != nil else { return -1 }

    // Actual send would use NIO
    return length
}

/// Receive data from socket
/// - Parameters:
///   - socketPtr: Socket handle
///   - buffer: Buffer to receive into
///   - maxLength: Maximum bytes to receive
/// - Returns: Bytes received or -1 on error
@_cdecl("aro_socket_recv")
public func aro_socket_recv(
    _ socketPtr: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ maxLength: Int
) -> Int {
    guard socketPtr != nil,
          buffer != nil else { return -1 }

    // Actual receive would use NIO
    return 0
}

/// Close socket
/// - Parameter socketPtr: Socket handle
@_cdecl("aro_socket_close")
public func aro_socket_close(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }

    let handle = Unmanaged<SocketHandle>.fromOpaque(ptr).takeUnretainedValue()
    handle.isConnected = false
}

/// Destroy socket
/// - Parameter socketPtr: Socket handle
@_cdecl("aro_socket_destroy")
public func aro_socket_destroy(_ socketPtr: UnsafeMutableRawPointer?) {
    guard let ptr = socketPtr else { return }
    Unmanaged<SocketHandle>.fromOpaque(ptr).release()
}

#endif  // !os(Windows)
