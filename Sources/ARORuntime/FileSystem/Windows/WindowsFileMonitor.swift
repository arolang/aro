// ============================================================
// WindowsFileMonitor.swift
// ARO Runtime - File Monitor for Windows (Polling-based)
// ============================================================
//
// Windows-specific file monitoring implementation using a polling approach.
// This can be enhanced later to use ReadDirectoryChangesW for better performance.

#if os(Windows)

import Foundation

/// File Monitor implementation for Windows using polling
///
/// Provides file system monitoring functionality on Windows platform where
/// the FileMonitor library (using inotify/FSEvents) is not available.
public final class WindowsFileMonitor: FileMonitorService, @unchecked Sendable {
    // MARK: - Properties

    private let eventBus: EventBus
    private var watchedPaths: [String: WatchState] = [:]
    private var pollingTask: Task<Void, Never>?
    private let lock = NSLock()

    /// Polling interval in seconds
    private let pollingInterval: TimeInterval = 1.0

    // MARK: - Watch State

    private struct WatchState {
        let path: String
        var lastModified: [String: Date]  // filename -> modificationDate
        var lastFileList: Set<String>
    }

    // MARK: - Initialization

    public init(eventBus: EventBus = .shared) {
        self.eventBus = eventBus
    }

    deinit {
        pollingTask?.cancel()
    }

    // MARK: - FileMonitorService

    public func watch(path: String) async throws {
        let resolvedPath = (path as NSString).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw FileSystemError.pathNotFound(resolvedPath)
        }

        // Get initial state
        let initialState = try getDirectoryState(resolvedPath)

        lock.lock()
        watchedPaths[resolvedPath] = WatchState(
            path: resolvedPath,
            lastModified: initialState.modificationDates,
            lastFileList: initialState.files
        )
        let shouldStartPolling = watchedPaths.count == 1
        lock.unlock()

        // Start polling if this is the first watch
        if shouldStartPolling {
            startPolling()
        }

        eventBus.publish(FileMonitorStartedEvent(path: resolvedPath))
        print("File monitoring started for: \(resolvedPath) (Windows/Polling)")
    }

    public func unwatch(path: String) async throws {
        let resolvedPath = (path as NSString).expandingTildeInPath

        lock.lock()
        watchedPaths.removeValue(forKey: resolvedPath)
        let shouldStopPolling = watchedPaths.isEmpty
        lock.unlock()

        // Stop polling if no more watches
        if shouldStopPolling {
            stopPolling()
        }

        eventBus.publish(FileMonitorStoppedEvent(path: resolvedPath))
        print("File monitoring stopped for: \(resolvedPath) (Windows/Polling)")
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                checkForChanges()
                try? await Task.sleep(nanoseconds: UInt64(pollingInterval * 1_000_000_000))
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func checkForChanges() {
        lock.lock()
        let paths = watchedPaths
        lock.unlock()

        for (path, state) in paths {
            do {
                let currentState = try getDirectoryState(path)

                // Check for new files
                let newFiles = currentState.files.subtracting(state.lastFileList)
                for file in newFiles {
                    let fullPath = (path as NSString).appendingPathComponent(file)
                    eventBus.publish(FileCreatedEvent(path: fullPath))
                }

                // Check for deleted files
                let deletedFiles = state.lastFileList.subtracting(currentState.files)
                for file in deletedFiles {
                    let fullPath = (path as NSString).appendingPathComponent(file)
                    eventBus.publish(FileDeletedEvent(path: fullPath))
                }

                // Check for modified files
                for (file, modDate) in currentState.modificationDates {
                    if let previousDate = state.lastModified[file], modDate > previousDate {
                        let fullPath = (path as NSString).appendingPathComponent(file)
                        eventBus.publish(FileModifiedEvent(path: fullPath))
                    }
                }

                // Update state
                lock.lock()
                watchedPaths[path]?.lastModified = currentState.modificationDates
                watchedPaths[path]?.lastFileList = currentState.files
                lock.unlock()

            } catch {
                // Directory may have been deleted
                eventBus.publish(FileDeletedEvent(path: path))
            }
        }
    }

    private func getDirectoryState(_ path: String) throws -> (files: Set<String>, modificationDates: [String: Date]) {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)

        var files = Set<String>()
        var modDates: [String: Date] = [:]

        for item in contents {
            files.insert(item)
            let fullPath = (path as NSString).appendingPathComponent(item)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let modDate = attrs[.modificationDate] as? Date {
                modDates[item] = modDate
            }
        }

        return (files, modDates)
    }
}

// MARK: - File Monitor Events (Windows-specific additions)

/// Event emitted when file monitoring starts
public struct FileMonitorStartedEvent: RuntimeEvent {
    public static var eventType: String { "file.monitor.started" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

/// Event emitted when file monitoring stops
public struct FileMonitorStoppedEvent: RuntimeEvent {
    public static var eventType: String { "file.monitor.stopped" }
    public let timestamp: Date
    public let path: String

    public init(path: String) {
        self.timestamp = Date()
        self.path = path
    }
}

#endif  // os(Windows)
