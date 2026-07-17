// ============================================================
// FileWatcherBridge.swift
// ARORuntime - C-callable File Watcher Interface
// ============================================================
//
// Owns the C-ABI bridge for filesystem watching. Contains the
// platform-specific FileWatcherHandle implementations (FSEvents on macOS,
// inotify on Linux, polling fallback elsewhere) and the Windows stubs.
// Extracted from ServiceBridge.swift (issue #313) — pure move, no behaviour change.

import Foundation
import AROParser

#if os(macOS)
import CoreServices
#endif

#if !os(Windows)

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

        // Publish domain event to EventBus so compiled binary file event handlers are triggered.
        // DomainEvent eventType: "file.created" | "file.modified" | "file.deleted"
        // DomainEvent payload:   { "path": String }
        let domainEventType = "file.\(eventType.lowercased())"
        EventBus.shared.publish(DomainEvent(eventType: domainEventType, payload: ["path": path]))
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
    let stopSemaphore = DispatchSemaphore(value: 0)

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
        stopSemaphore.signal()
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
                // Wait up to 100 ms for a stop signal; break immediately if stop() was called
                if handle.stopSemaphore.wait(timeout: .now() + 0.1) == .success { break }
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
    let stopSemaphore = DispatchSemaphore(value: 0)

    init(path: String) {
        self.path = path
    }

    func stop() {
        isWatching = false
        stopSemaphore.signal()
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

        while true {
            // Wait up to 1 s; if stop() signals the semaphore, exit immediately
            if handle.stopSemaphore.wait(timeout: .now() + 1.0) == .success { break }
            guard handle.isWatching else { break }

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

#else  // os(Windows)

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

#endif  // !os(Windows)
