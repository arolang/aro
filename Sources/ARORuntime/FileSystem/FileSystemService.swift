// ============================================================
// FileSystemService.swift
// ARO Runtime - File System Service
// ============================================================

import Foundation

// MARK: - File Info (Platform-agnostic)

/// Information about a file or directory
public struct FileInfo: Sendable, Equatable {
    public let name: String
    public let path: String
    public let size: Int
    public let isFile: Bool
    public let isDirectory: Bool
    public let created: Date?
    public let modified: Date?
    public let accessed: Date?
    public let permissions: String?
    public let owner: String?
    public let group: String?

    public init(
        name: String,
        path: String,
        size: Int,
        isFile: Bool,
        isDirectory: Bool,
        created: Date?,
        modified: Date?,
        accessed: Date?,
        permissions: String?,
        owner: String? = nil,
        group: String? = nil
    ) {
        self.name = name
        self.path = path
        self.size = size
        self.isFile = isFile
        self.isDirectory = isDirectory
        self.created = created
        self.modified = modified
        self.accessed = accessed
        self.permissions = permissions
        self.owner = owner
        self.group = group
    }

    /// Convert to dictionary for ARO context binding
    public func toDictionary() -> [String: any Sendable] {
        let dateFormatter = ISO8601DateFormatter()
        var dict: [String: any Sendable] = [
            "name": name,
            "path": path,
            "size": size,
            "isFile": isFile,
            "isDirectory": isDirectory
        ]

        if let created = created {
            dict["created"] = dateFormatter.string(from: created)
        }
        if let modified = modified {
            dict["modified"] = dateFormatter.string(from: modified)
        }
        if let accessed = accessed {
            dict["accessed"] = dateFormatter.string(from: accessed)
        }
        if let permissions = permissions {
            dict["permissions"] = permissions
        }
        if let owner = owner {
            dict["owner"] = owner
        }
        if let group = group {
            dict["group"] = group
        }

        return dict
    }
}

// MARK: - File System Errors (Platform-agnostic)

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
    case copyError(String, String, String)
    case moveError(String, String, String)
    case statError(String, String)
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
        case .copyError(let source, let destination, let reason):
            return "Error copying \(source) to \(destination): \(reason)"
        case .moveError(let source, let destination, let reason):
            return "Error moving \(source) to \(destination): \(reason)"
        case .statError(let path, let reason):
            return "Error getting stats for \(path): \(reason)"
        }
    }
}

// MARK: - File System Events (Platform-agnostic)

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

// ============================================================
// Platform-specific implementations
// ============================================================

#if !os(Windows)
// macOS and Linux implementation with FileMonitor support

import FileMonitor
import FileMonitorShared

/// File System Service implementation with file monitoring
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

    /// Touch a file (create or update modification time)
    public func touch(path: String) async throws {
        let url = URL(fileURLWithPath: path)

        // Create parent directory if needed
        let parentDir = url.deletingLastPathComponent().path
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: path) {
            // Update modification time
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        } else {
            // Create empty file
            fileManager.createFile(atPath: path, contents: nil, attributes: nil)
        }
    }

    // MARK: - ARO-0036: Extended File Operations

    /// Get file or directory stats
    public func stat(path: String) async throws -> FileInfo {
        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path)
        }

        let url = URL(fileURLWithPath: path)
        let attributes = try fileManager.attributesOfItem(atPath: path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let size = (attributes[.size] as? Int) ?? 0
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date
        let posixPermissions = attributes[.posixPermissions] as? Int
        let owner = attributes[.ownerAccountName] as? String
        let group = attributes[.groupOwnerAccountName] as? String

        return FileInfo(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            isFile: !isDirectory,
            isDirectory: isDirectory,
            created: created,
            modified: modified,
            accessed: nil,  // Not available via FileManager
            permissions: posixPermissions.map { formatPermissions($0) },
            owner: owner,
            group: group
        )
    }

    /// Format Unix permissions as string (e.g., "rwxr-xr-x")
    private func formatPermissions(_ mode: Int) -> String {
        let chars = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        let owner = (mode >> 6) & 0o7
        let group = (mode >> 3) & 0o7
        let other = mode & 0o7
        return chars[owner] + chars[group] + chars[other]
    }

    /// List directory with optional pattern matching
    public func list(directory: String, pattern: String? = nil, recursive: Bool = false) async throws -> [FileInfo] {
        guard fileManager.fileExists(atPath: directory) else {
            throw FileSystemError.directoryNotFound(directory)
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            throw FileSystemError.directoryNotFound(directory)
        }

        var results: [FileInfo] = []
        let directoryURL = URL(fileURLWithPath: directory)

        if recursive {
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: []
            )

            while let url = enumerator?.nextObject() as? URL {
                if let info = try? await statURL(url), matchesPattern(info.name, pattern: pattern) {
                    results.append(info)
                }
            }
        } else {
            let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

            for url in contents {
                if let info = try? await statURL(url), matchesPattern(info.name, pattern: pattern) {
                    results.append(info)
                }
            }
        }

        // Sort by path for deterministic order across platforms
        return results.sorted { $0.path < $1.path }
    }

    /// Get stats from URL
    private func statURL(_ url: URL) async throws -> FileInfo {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

        let isDirectory = resourceValues.isDirectory ?? false
        let size = resourceValues.fileSize ?? 0
        let created = resourceValues.creationDate
        let modified = resourceValues.contentModificationDate

        return FileInfo(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            isFile: !isDirectory,
            isDirectory: isDirectory,
            created: created,
            modified: modified,
            accessed: nil,
            permissions: nil
        )
    }

    /// Check if filename matches glob pattern
    private func matchesPattern(_ name: String, pattern: String?) -> Bool {
        guard let pattern = pattern, !pattern.isEmpty else {
            return true
        }

        // Convert glob pattern to regex
        var regex = "^"
        for char in pattern {
            switch char {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".":
                regex += "\\."
            case "[", "]":
                regex += String(char)
            default:
                regex += String(char)
            }
        }
        regex += "$"

        return (try? NSRegularExpression(pattern: regex, options: .caseInsensitive))?.firstMatch(
            in: name,
            options: [],
            range: NSRange(name.startIndex..., in: name)
        ) != nil
    }

    /// Check if path exists and return type
    public func existsWithType(path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
        return (exists, isDir.boolValue)
    }

    /// Copy file or directory
    public func copy(source: String, destination: String) async throws {
        guard fileManager.fileExists(atPath: source) else {
            throw FileSystemError.fileNotFound(source)
        }

        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: destination)
        let destDir = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }

        do {
            try fileManager.copyItem(atPath: source, toPath: destination)
        } catch {
            throw FileSystemError.copyError(source, destination, error.localizedDescription)
        }
    }

    /// Move file or directory
    public func move(source: String, destination: String) async throws {
        guard fileManager.fileExists(atPath: source) else {
            throw FileSystemError.fileNotFound(source)
        }

        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: destination)
        let destDir = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }

        do {
            try fileManager.moveItem(atPath: source, toPath: destination)
            eventBus.publish(FileRenamedEvent(oldPath: source, newPath: destination))
        } catch {
            throw FileSystemError.moveError(source, destination, error.localizedDescription)
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
            eventBus.publish(FileCreatedEvent(path: url.path))

        case .changed(let url):
            eventBus.publish(FileModifiedEvent(path: url.path))

        case .deleted(let url):
            eventBus.publish(FileDeletedEvent(path: url.path))
        }
    }
}

#else
// Windows implementation without FileMonitor

/// File System Service implementation for Windows
///
/// Provides file I/O operations without file monitoring capabilities.
/// File watching is not available on Windows.
public final class AROFileSystemService: FileSystemService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private let fileManager = FileManager.default

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
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

    /// Touch a file (create or update modification time)
    public func touch(path: String) async throws {
        let url = URL(fileURLWithPath: path)

        // Create parent directory if needed
        let parentDir = url.deletingLastPathComponent().path
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true, attributes: nil)
        }

        if fileManager.fileExists(atPath: path) {
            // Update modification time
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
        } else {
            // Create empty file
            fileManager.createFile(atPath: path, contents: nil, attributes: nil)
        }
    }

    // MARK: - ARO-0036: Extended File Operations

    /// Get file or directory stats
    public func stat(path: String) async throws -> FileInfo {
        guard fileManager.fileExists(atPath: path) else {
            throw FileSystemError.fileNotFound(path)
        }

        let url = URL(fileURLWithPath: path)
        let attributes = try fileManager.attributesOfItem(atPath: path)

        let fileType = attributes[.type] as? FileAttributeType
        let isDirectory = fileType == .typeDirectory
        let size = (attributes[.size] as? Int) ?? 0
        let created = attributes[.creationDate] as? Date
        let modified = attributes[.modificationDate] as? Date

        return FileInfo(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            isFile: !isDirectory,
            isDirectory: isDirectory,
            created: created,
            modified: modified,
            accessed: nil,
            permissions: nil,  // POSIX permissions not applicable on Windows
            owner: nil,        // Owner info not applicable on Windows
            group: nil
        )
    }

    /// List directory with optional pattern matching
    public func list(directory: String, pattern: String? = nil, recursive: Bool = false) async throws -> [FileInfo] {
        guard fileManager.fileExists(atPath: directory) else {
            throw FileSystemError.directoryNotFound(directory)
        }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            throw FileSystemError.directoryNotFound(directory)
        }

        var results: [FileInfo] = []
        let directoryURL = URL(fileURLWithPath: directory)

        if recursive {
            let enumerator = fileManager.enumerator(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey],
                options: []
            )

            while let url = enumerator?.nextObject() as? URL {
                if let info = try? await statURL(url), matchesPattern(info.name, pattern: pattern) {
                    results.append(info)
                }
            }
        } else {
            let contents = try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

            for url in contents {
                if let info = try? await statURL(url), matchesPattern(info.name, pattern: pattern) {
                    results.append(info)
                }
            }
        }

        // Sort by path for deterministic order across platforms
        return results.sorted { $0.path < $1.path }
    }

    /// Get stats from URL
    private func statURL(_ url: URL) async throws -> FileInfo {
        let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])

        let isDirectory = resourceValues.isDirectory ?? false
        let size = resourceValues.fileSize ?? 0
        let created = resourceValues.creationDate
        let modified = resourceValues.contentModificationDate

        return FileInfo(
            name: url.lastPathComponent,
            path: url.path,
            size: size,
            isFile: !isDirectory,
            isDirectory: isDirectory,
            created: created,
            modified: modified,
            accessed: nil,
            permissions: nil
        )
    }

    /// Check if filename matches glob pattern
    private func matchesPattern(_ name: String, pattern: String?) -> Bool {
        guard let pattern = pattern, !pattern.isEmpty else {
            return true
        }

        // Convert glob pattern to regex
        var regex = "^"
        for char in pattern {
            switch char {
            case "*":
                regex += ".*"
            case "?":
                regex += "."
            case ".":
                regex += "\\."
            case "[", "]":
                regex += String(char)
            default:
                regex += String(char)
            }
        }
        regex += "$"

        return (try? NSRegularExpression(pattern: regex, options: .caseInsensitive))?.firstMatch(
            in: name,
            options: [],
            range: NSRange(name.startIndex..., in: name)
        ) != nil
    }

    /// Check if path exists and return type
    public func existsWithType(path: String) -> (exists: Bool, isDirectory: Bool) {
        var isDir: ObjCBool = false
        let exists = fileManager.fileExists(atPath: path, isDirectory: &isDir)
        return (exists, isDir.boolValue)
    }

    /// Copy file or directory
    public func copy(source: String, destination: String) async throws {
        guard fileManager.fileExists(atPath: source) else {
            throw FileSystemError.fileNotFound(source)
        }

        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: destination)
        let destDir = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }

        do {
            try fileManager.copyItem(atPath: source, toPath: destination)
        } catch {
            throw FileSystemError.copyError(source, destination, error.localizedDescription)
        }
    }

    /// Move file or directory
    public func move(source: String, destination: String) async throws {
        guard fileManager.fileExists(atPath: source) else {
            throw FileSystemError.fileNotFound(source)
        }

        // Create destination parent directory if needed
        let destURL = URL(fileURLWithPath: destination)
        let destDir = destURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destDir.path) {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        }

        // Remove destination if exists
        if fileManager.fileExists(atPath: destination) {
            try fileManager.removeItem(atPath: destination)
        }

        do {
            try fileManager.moveItem(atPath: source, toPath: destination)
            eventBus.publish(FileRenamedEvent(oldPath: source, newPath: destination))
        } catch {
            throw FileSystemError.moveError(source, destination, error.localizedDescription)
        }
    }
}

#endif  // os(Windows)
