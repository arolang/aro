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
            systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeSocketServer] Failed to listen")
            systemClose(serverFd)
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
            systemClose(fd)
        }

        // Close server socket
        if serverFd >= 0 {
            systemClose(serverFd)
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

        systemClose(fd)
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

        // Set up handlers for echo behavior (for now - will be customizable)
        nativeSocketServer?.onConnect { connectionId, remoteAddress in
            print("[Handle Client Connected] SocketConnection(id: \"\(connectionId)\", remoteAddress: \"\(remoteAddress)\")")
        }

        nativeSocketServer?.onData { connectionId, data in
            // Echo the data back
            _ = nativeSocketServer?.send(data: data, to: connectionId)
            if let str = String(data: data, encoding: .utf8) {
                print("[Handle Data Received] Echoed: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
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

// MARK: - Native HTTP Server (BSD Sockets)

/// Request handler type for native HTTP server
public typealias NativeHTTPRequestHandler = (String, String, [String: String], Data?) -> (Int, [String: String], Data?)

/// Native HTTP Server using BSD sockets
/// This provides a working HTTP server for compiled binaries
public final class NativeHTTPServer: @unchecked Sendable {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let lock = NSLock()
    private var requestHandler: NativeHTTPRequestHandler?

    public let port: Int

    public init(port: Int) {
        self.port = port
    }

    deinit {
        stop()
    }

    /// Set request handler
    public func onRequest(_ handler: @escaping NativeHTTPRequestHandler) {
        requestHandler = handler
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
            systemClose(serverFd)
            serverFd = -1
            return false
        }

        // Listen
        guard listen(serverFd, 10) == 0 else {
            print("[NativeHTTPServer] Failed to listen")
            systemClose(serverFd)
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
            systemClose(serverFd)
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

        let bytesRead = recv(fd, &buffer, buffer.count, 0)

        guard bytesRead > 0 else {
            systemClose(fd)
            return
        }

        let requestData = Data(buffer[0..<bytesRead])
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            systemClose(fd)
            return
        }

        // Parse HTTP request
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            systemClose(fd)
            return
        }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            sendResponse(fd: fd, statusCode: 400, body: "Bad Request")
            systemClose(fd)
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

        // Find body (after empty line)
        var body: Data? = nil
        if let emptyLineIndex = lines.firstIndex(of: "") {
            let bodyLines = lines.dropFirst(emptyLineIndex + 1)
            let bodyString = bodyLines.joined(separator: "\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
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

        systemClose(fd)
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
}

/// Global native HTTP server instance
nonisolated(unsafe) public var nativeHTTPServer: NativeHTTPServer?
private let httpServerLock = NSLock()

/// Registered feature set handlers for HTTP routing
/// Maps operationId to a function that executes the feature set
nonisolated(unsafe) public var httpRouteHandlers: [String: (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?] = [:]

/// Route registry for matching paths to operationIds
nonisolated(unsafe) public var httpRoutes: [(method: String, path: String, operationId: String)] = []

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

        // Set up request handler
        nativeHTTPServer?.onRequest { method, path, headers, body in
            // Match route to operationId
            var matchedOperationId: String? = nil

            for route in httpRoutes {
                if route.method == method && route.path == path {
                    matchedOperationId = route.operationId
                    break
                }
            }

            // If route matched, try to invoke the feature set
            if let opId = matchedOperationId {
                // First check for registered handler
                if let handler = httpRouteHandlers[opId] {
                    _ = handler(contextPtr)
                    return (200, ["Content-Type": "application/json"], "{\"message\":\"Hello World\"}".data(using: .utf8))
                }

                // Try to find the compiled feature set function via dlsym
                let functionName = "featureset_\(opId)"
                if let handle = dlopen(nil, RTLD_NOW),
                   let sym = dlsym(handle, functionName) {
                    typealias FSFunction = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
                    let function = unsafeBitCast(sym, to: FSFunction.self)
                    _ = function(contextPtr)
                    // For now, return static response - proper response extraction coming later
                    return (200, ["Content-Type": "application/json"], "{\"message\":\"Hello World\"}".data(using: .utf8))
                }

                // Route matched but no handler - return placeholder success
                return (200, ["Content-Type": "application/json"], "{\"message\":\"Hello World\"}".data(using: .utf8))
            }

            // Default: Not found
            return (404, ["Content-Type": "application/json"], "{\"error\":\"Not Found\"}".data(using: .utf8))
        }
    }

    return nativeHTTPServer?.start() == true ? 0 : -1
}

/// Start native HTTP server with OpenAPI spec from working directory
/// If port is 0, reads port from OpenAPI spec's server URL
@_cdecl("aro_native_http_server_start_with_openapi")
public func aro_native_http_server_start_with_openapi(_ port: Int32, _ contextPtr: UnsafeMutableRawPointer?) -> Int32 {
    httpServerLock.lock()

    var finalPort = port

    // Try to load openapi.yaml from current directory
    let currentDir = FileManager.default.currentDirectoryPath
    let openapiPath = currentDir + "/openapi.yaml"

    if let openapiContent = try? String(contentsOfFile: openapiPath, encoding: .utf8) {
        // Simple YAML parsing for routes
        parseOpenAPIRoutes(openapiContent)

        // Extract port from server URL if not explicitly specified
        if finalPort == 0 {
            finalPort = Int32(extractPortFromOpenAPI(openapiContent))
        }
    }

    // Default to 8080 if no port found
    if finalPort == 0 {
        finalPort = 8080
    }

    httpServerLock.unlock()

    return aro_native_http_server_start(finalPort, contextPtr)
}

/// Extract port from OpenAPI spec's server URL
private func extractPortFromOpenAPI(_ yaml: String) -> Int {
    let lines = yaml.components(separatedBy: "\n")

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Look for "url: http://localhost:PORT" pattern
        if trimmed.hasPrefix("- url:") || trimmed.hasPrefix("url:") {
            let urlPart = trimmed.replacingOccurrences(of: "- url:", with: "")
                .replacingOccurrences(of: "url:", with: "")
                .trimmingCharacters(in: .whitespaces)

            // Extract port from URL
            if let colonRange = urlPart.range(of: "://") {
                let afterScheme = String(urlPart[colonRange.upperBound...])
                // Look for :PORT at the end
                if let lastColon = afterScheme.lastIndex(of: ":") {
                    let portString = String(afterScheme[afterScheme.index(after: lastColon)...])
                        .components(separatedBy: CharacterSet(charactersIn: "/")).first ?? ""
                    if let port = Int(portString) {
                        return port
                    }
                }
            }
        }
    }

    return 0
}

/// Simple OpenAPI route parser
private func parseOpenAPIRoutes(_ yaml: String) {
    let lines = yaml.components(separatedBy: "\n")
    var currentPath: String? = nil
    var currentMethod: String? = nil

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Check for path
        if line.hasPrefix("  /") && line.contains(":") {
            let pathPart = line.trimmingCharacters(in: .whitespaces)
            if let colonIndex = pathPart.firstIndex(of: ":") {
                currentPath = String(pathPart[..<colonIndex])
            }
        }
        // Check for method
        else if trimmed.hasPrefix("get:") || trimmed.hasPrefix("post:") ||
                trimmed.hasPrefix("put:") || trimmed.hasPrefix("delete:") {
            currentMethod = String(trimmed.dropLast()) // Remove ":"
        }
        // Check for operationId
        else if trimmed.hasPrefix("operationId:") {
            let opId = trimmed.replacingOccurrences(of: "operationId:", with: "")
                .trimmingCharacters(in: .whitespaces)

            if let path = currentPath, let method = currentMethod {
                httpRoutes.append((method: method.uppercased(), path: path, operationId: opId))
            }
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

#endif  // !os(Windows)
