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

// MARK: - One mapping, three backends

/// The kinds of change a file watcher reports.
///
/// Three backends derive these from three unrelated sources — FSEvents flags,
/// inotify masks, a polling diff — and the interpreter derives them from
/// FileMonitor's `FileChangeEvent`. Naming them once is what lets the four
/// agree (GitLab #693).
enum FileWatchChange: String {
    case created = "Created"
    case modified = "Modified"
    case deleted = "Deleted"

    var domainEventType: String { "file.\(rawValue.lowercased())" }
}

/// Announce a change exactly as `AROFileSystemService.handleFileEvent` does:
/// the typed event, then the domain event carrying `path`.
///
/// Only the FSEvents backend published anything before this existed. inotify
/// and the polling fallback merely printed a line, so a `File Event Handler`
/// in a Linux binary never ran at all — which is why
/// `Examples/MultiService/expected.linux-compiled.txt` has no file lines in it.
func reportFileWatchChange(_ change: FileWatchChange, at path: String) {
    print("[FileMonitor] \(change.rawValue): \(path)")

    switch change {
    case .created:  EventBus.shared.publish(FileCreatedEvent(path: path))
    case .modified: EventBus.shared.publish(FileModifiedEvent(path: path))
    case .deleted:  EventBus.shared.publish(FileDeletedEvent(path: path))
    }

    // DomainEvent is what a *compiled* handler is registered against
    // (`aro_runtime_register_handler` matches on this string).
    EventBus.shared.publish(DomainEvent(eventType: change.domainEventType, payload: ["path": path]))
}

/// Which paths a watcher has already announced as existing.
///
/// FSEvents reports the flags *accumulated* for a path, not one flag per
/// operation: a file that is created and then written arrives with
/// `ItemCreated` and `ItemModified` set together. The old code broke that tie
/// by asking whether the file exists now — which answers "yes", so every
/// creation was announced as a modification. Existence cannot distinguish
/// them; having announced the path before can.
final class WatchedPathLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var known: Set<String> = []

    /// Record what is already there, so the first *edit* of a pre-existing
    /// file is a modification rather than a creation.
    func seed(directory: String) {
        // try?: the directory may vanish or be unreadable between the watch
        // being added and this listing; an empty ledger is the safe start.
        guard let entries = try? FileManager.default.subpathsOfDirectory(atPath: directory) else { return }
        lock.lock(); defer { lock.unlock() }
        known = Set(entries.map { directory + "/" + $0 })
    }

    /// Classify one raw event. Returns the changes to announce, in order.
    ///
    /// - Parameters:
    ///   - exists: whether the path is there *now*.
    ///   - sawCreate: whether the platform said a creation was among the
    ///     accumulated flags.
    func classify(_ path: String, exists: Bool, sawCreate: Bool) -> [FileWatchChange] {
        lock.lock(); defer { lock.unlock() }

        if exists {
            return known.insert(path).inserted ? [.created] : [.modified]
        }
        if known.remove(path) != nil {
            return [.deleted]
        }
        // Gone now and never announced: the file's whole life fell inside one
        // coalescing window. Report both halves rather than dropping it — a
        // handler that logs creations should still see this one.
        return sawCreate ? [.created, .deleted] : []
    }
}

// MARK: - File Watcher Bridge (Platform-specific)

/// Registry of live file-watcher handles, shared by all platform backends.
///
/// Exactly one platform-specific `FileWatcherHandle` class is compiled per
/// build (FSEvents on macOS, inotify on Linux, polling elsewhere; Windows
/// compiles stateless stubs). Historically each backend declared its own
/// `fileWatcherHandles` dictionary guarded by its own `NSLock` — three
/// identical lock+dictionary pairs that could never coexist in one binary.
/// This registry consolidates them into a single lock-protected owner
/// (issue #321).
///
/// Concurrency invariant: `@unchecked Sendable` is sound because `lock`
/// guards all access to `handles`, the only mutable state. Any state added
/// to this type must likewise only be touched while holding `lock`.
final class FileWatcherRegistry: @unchecked Sendable {
    static let shared = FileWatcherRegistry()

    private let lock = NSLock()
    private var handles: [UnsafeMutableRawPointer: FileWatcherHandle] = [:]

    private init() {}

    /// Track a live handle under its opaque pointer (`aro_file_watcher_create`).
    func register(_ handle: FileWatcherHandle, for pointer: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        handles[pointer] = handle
    }

    /// Stop tracking the handle for `pointer` (`aro_file_watcher_destroy`).
    func unregister(_ pointer: UnsafeMutableRawPointer) {
        lock.lock(); defer { lock.unlock() }
        handles.removeValue(forKey: pointer)
    }
}

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

    /// What the flags cannot say. See `WatchedPathLedger`.
    let ledger = WatchedPathLedger()

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

    // Without the handle we have no ledger, so no way to tell a creation from
    // an edit. Dropping the batch is worse than reporting it imprecisely.
    let ledger = clientCallBackInfo.map {
        Unmanaged<FileWatcherHandle>.fromOpaque($0).takeUnretainedValue().ledger
    }

    for i in 0..<numEvents {
        guard let path = paths[i] as? String else { continue }
        let flags = eventFlags[i]

        let sawCreate = (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0
        let sawRemove = (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0
        let sawRename = (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0
        let sawModify = (flags & UInt32(kFSEventStreamEventFlagItemModified)) != 0 ||
                        (flags & UInt32(kFSEventStreamEventFlagItemInodeMetaMod)) != 0

        // Nothing we report on — an xattr change, a permissions change.
        guard sawCreate || sawRemove || sawRename || sawModify else { continue }

        let exists = FileManager.default.fileExists(atPath: path)

        // A rename is two events, one per path, and each is a creation or a
        // removal from the watcher's point of view — which is also how the
        // interpreter sees it, since FileMonitor has no rename case.
        let changes = ledger?.classify(path, exists: exists, sawCreate: sawCreate || sawRename)
            ?? [exists ? (sawCreate ? .created : .modified) : .deleted]

        for change in changes {
            reportFileWatchChange(change, at: path)
        }
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

    FileWatcherRegistry.shared.register(handle, for: pointer)

    return UnsafeMutableRawPointer(pointer)
}

/// Start watching for file changes using FSEvents
@_cdecl("aro_file_watcher_start")
public func aro_file_watcher_start(_ watcherPtr: UnsafeMutableRawPointer?) -> Int32 {
    guard let ptr = watcherPtr else { return -1 }

    let handle = Unmanaged<FileWatcherHandle>.fromOpaque(ptr).takeUnretainedValue()

    // Already watching
    if handle.isWatching { return 0 }

    // Remember what is already there, so the first edit of a pre-existing
    // file reads as a modification rather than a creation.
    handle.ledger.seed(directory: handle.path)

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

    FileWatcherRegistry.shared.unregister(ptr)

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

    FileWatcherRegistry.shared.register(handle, for: pointer)

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

                        // inotify delivers one event per operation, so the
                        // mask says outright what happened — no ledger needed.
                        // A move is a creation at the destination and a
                        // deletion at the source, which is also how the
                        // interpreter's FileMonitor sees it (it has no rename
                        // case), so the two halves map onto those rather than
                        // onto a `file.renamed` nothing subscribes to.
                        let change: FileWatchChange
                        if (event.mask & UInt32(IN_CREATE)) != 0 || (event.mask & UInt32(IN_MOVED_TO)) != 0 {
                            change = .created
                        } else if (event.mask & UInt32(IN_DELETE)) != 0 || (event.mask & UInt32(IN_MOVED_FROM)) != 0 {
                            change = .deleted
                        } else if (event.mask & UInt32(IN_MODIFY)) != 0 {
                            change = .modified
                        } else {
                            offset += MemoryLayout<inotify_event>.size + Int(event.len)
                            return
                        }

                        // `len == 0` is an event on the watched directory
                        // itself; there is no file to name.
                        if event.len > 0 {
                            let namePtr = UnsafeRawPointer(bufferPtr.baseAddress! + offset + MemoryLayout<inotify_event>.size)
                                .assumingMemoryBound(to: CChar.self)
                            let name = String(cString: namePtr)
                            reportFileWatchChange(change, at: handle.path + "/" + name)
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

    FileWatcherRegistry.shared.unregister(ptr)

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

    FileWatcherRegistry.shared.register(handle, for: pointer)

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

    // Start polling thread.
    // Note on try? in this polling loop: the watched directory and its files
    // can appear/vanish/change permissions at any moment (that churn is the
    // very thing being monitored), so listing or stat'ing may fail transiently.
    // Skipping the file or retrying on the next 1 s tick is the intended
    // recovery — these failures are expected, not data loss.
    DispatchQueue.global(qos: .utility).async {
        // Get initial file list (try?: directory may not exist yet; the poll
        // loop below picks it up once it appears)
        var knownFiles: Set<String> = []
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: handle.path) {
            knownFiles = Set(contents)
            for file in contents {
                let fullPath = handle.path + "/" + file
                // try?: file may vanish between listing and stat (TOCTOU race)
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

            // try?: directory may be temporarily unreadable; retry next tick
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: handle.path) else {
                continue
            }

            let currentFiles = Set(contents)

            // Check for new files
            for file in currentFiles.subtracting(knownFiles) {
                let fullPath = handle.path + "/" + file
                reportFileWatchChange(.created, at: fullPath)
                // try?: file may vanish between listing and stat (TOCTOU race)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    handle.lastModified[file] = modDate
                }
            }

            // Check for deleted files
            for file in knownFiles.subtracting(currentFiles) {
                let fullPath = handle.path + "/" + file
                reportFileWatchChange(.deleted, at: fullPath)
                handle.lastModified.removeValue(forKey: file)
            }

            // Check for modified files
            for file in currentFiles.intersection(knownFiles) {
                let fullPath = handle.path + "/" + file
                // try?: file may vanish between listing and stat (TOCTOU race)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                   let modDate = attrs[.modificationDate] as? Date {
                    if let lastMod = handle.lastModified[file], modDate > lastMod {
                        reportFileWatchChange(.modified, at: fullPath)
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

    FileWatcherRegistry.shared.unregister(ptr)

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
