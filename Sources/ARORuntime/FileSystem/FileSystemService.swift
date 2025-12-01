// ============================================================
// FileSystemService.swift
// ARO Runtime - File System Service
// ============================================================

import Foundation
import FileMonitor
import FileMonitorShared

/// File System Service implementation
///
/// Provides file I/O operations and file monitoring capabilities
/// using the FileMonitor library.
public final class AROFileSystemService: FileSystemService, FileMonitorService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var monitors: [String: FileMonitor] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
    }

    deinit {
        // Stop all monitors
        for monitor in monitors.values {
            monitor.stop()
        }
    }

    // MARK: - FileSystemService

    public func read(path: String) async throws -> String {
        let url = URL(fileURLWithPath: path)

        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw FileSystemError.readError(path, error.localizedDescription)
        }
    }

    public func write(path: String, content: String) async throws {
        let url = URL(fileURLWithPath: path)

        // Create directory if needed
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            eventBus.publish(FileWrittenEvent(path: path))
        } catch {
            throw FileSystemError.writeError(path, error.localizedDescription)
        }
    }

    public func exists(path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    // MARK: - Extended File Operations

    /// Read file as Data
    public func readData(path: String) async throws -> Data {
        let url = URL(fileURLWithPath: path)

        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path)
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw FileSystemError.readError(path, error.localizedDescription)
        }
    }

    /// Write Data to file
    public func writeData(path: String, data: Data) async throws {
        let url = URL(fileURLWithPath: path)

        // Create directory if needed
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        do {
            try data.write(to: url)
            eventBus.publish(FileWrittenEvent(path: path))
        } catch {
            throw FileSystemError.writeError(path, error.localizedDescription)
        }
    }

    /// Append to file
    public func append(path: String, content: String) async throws {
        let url = URL(fileURLWithPath: path)

        if fileManager.fileExists(atPath: path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }

            handle.seekToEndOfFile()
            if let data = content.data(using: .utf8) {
                handle.write(data)
            }
        } else {
            try await write(path: path, content: content)
        }
    }

    /// Delete file
    public func delete(path: String) async throws {
        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path)
        }

        do {
            try fileManager.removeItem(atPath: path)
            eventBus.publish(FileDeletedEvent(path: path))
        } catch {
            throw FileSystemError.deleteError(path, error.localizedDescription)
        }
    }

    /// List directory contents
    public func list(directory: String) async throws -> [String] {
        guard fileManager.fileExists(atPath: directory) else {
            throw FileSystemError.directoryNotFound(directory)
        }

        do {
            return try fileManager.contentsOfDirectory(atPath: directory)
        } catch {
            throw FileSystemError.listError(directory, error.localizedDescription)
        }
    }

    /// Create directory
    public func createDirectory(path: String) async throws {
        do {
            try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw FileSystemError.createDirectoryError(path, error.localizedDescription)
        }
    }

    // MARK: - FileMonitorService

    // MARK: - Thread-safe helpers

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func getMonitor(_ path: String) -> FileMonitor? {
        withLock { monitors[path] }
    }

    private func setMonitor(_ path: String, monitor: FileMonitor?) {
        withLock { monitors[path] = monitor }
    }

    private func removeMonitor(_ path: String) -> FileMonitor? {
        withLock { monitors.removeValue(forKey: path) }
    }

    private func getAllMonitors() -> [String: FileMonitor] {
        withLock { monitors }
    }

    private func clearMonitors() {
        withLock { monitors.removeAll() }
    }

    public func watch(path: String) async throws {
        let url = URL(fileURLWithPath: path)

        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.pathNotFound(path)
        }

        // Check if already watching
        if getMonitor(path) != nil {
            return
        }

        // Create file monitor
        let monitor = try FileMonitor(directory: url)
        setMonitor(path, monitor: monitor)

        // Start watching and process events in a task
        try monitor.start()

        // Start async task to handle file events
        Task { [weak self, eventBus] in
            for await event in monitor.stream {
                self?.handleFileEvent(event, eventBus: eventBus)
            }
        }

        eventBus.publish(FileWatchStartedEvent(path: path))
    }

    public func unwatch(path: String) async throws {
        if let monitor = removeMonitor(path) {
            monitor.stop()
            eventBus.publish(FileWatchStoppedEvent(path: path))
        }
    }

    /// Stop all file monitors
    public func unwatchAll() {
        let currentMonitors = getAllMonitors()

        for (path, monitor) in currentMonitors {
            monitor.stop()
            eventBus.publish(FileWatchStoppedEvent(path: path))
        }
        clearMonitors()
    }

    // MARK: - Private

    private func handleFileEvent(_ event: FileChangeEvent, eventBus: EventBus) {
        switch event {
        case .added(let url):
            print("[FileMonitor] Created: \(url.path)")
            eventBus.publish(FileCreatedEvent(path: url.path))

        case .changed(let url):
            print("[FileMonitor] Modified: \(url.path)")
            eventBus.publish(FileModifiedEvent(path: url.path))

        case .deleted(let url):
            print("[FileMonitor] Deleted: \(url.path)")
            eventBus.publish(FileDeletedEvent(path: url.path))
        }
    }
}

// MARK: - File System Errors

/// Errors that can occur during file system operations
public enum FileSystemError: Error, Sendable {
    case fileNotFound(String)
    case directoryNotFound(String)
    case pathNotFound(String)
    case readError(String, String)
    case writeError(String, String)
    case deleteError(String, String)
    case listError(String, String)
    case createDirectoryError(String, String)
    case permissionDenied(String)
}

extension FileSystemError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .directoryNotFound(let path):
            return "Directory not found: \(path)"
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .readError(let path, let reason):
            return "Error reading \(path): \(reason)"
        case .writeError(let path, let reason):
            return "Error writing \(path): \(reason)"
        case .deleteError(let path, let reason):
            return "Error deleting \(path): \(reason)"
        case .listError(let path, let reason):
            return "Error listing \(path): \(reason)"
        case .createDirectoryError(let path, let reason):
            return "Error creating directory \(path): \(reason)"
        case .permissionDenied(let path):
            return "Permission denied: \(path)"
        }
    }
}

// MARK: - File System Events

/// Event emitted when a file is written
public struct FileWrittenEvent: RuntimeEvent {
    public static var eventType: String { "file.written" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// Event emitted when a file is renamed
public struct FileRenamedEvent: RuntimeEvent {
    public static var eventType: String { "file.renamed" }
    public let timestamp: Date
    public let oldPath: String
    public let newPath: String

    public init(oldPath: String, newPath: String) {
        self.timestamp = Date()
        self.oldPath = oldPath
        self.newPath = newPath
    }
}

/// Event emitted when file attributes change
public struct FileAttributesChangedEvent: RuntimeEvent {
    public static var eventType: String { "file.attributes_changed" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// Event emitted when file watching stops
public struct FileWatchStoppedEvent: RuntimeEvent {
    public static var eventType: String { "file.watch.stopped" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}
