// ============================================================
// StoreFlushService.swift
// ARO Runtime - Store File Write-Back Service
// ============================================================
//
// Manages write-back for writable .store files. Subscribes to
// RepositoryChangedEvent and flushes dirty repositories to disk
// using atomic writes (write to .tmp, then rename).

import Foundation

/// Service that flushes writable repository changes back to .store files
public actor StoreFlushService {

    /// Mapping from repository name to .store file path
    private var writableStores: [String: URL] = [:]

    /// Repositories that have been modified since last flush
    private var dirtyRepositories: Set<String> = []

    /// Pending debounce tasks per repository
    private var pendingFlush: [String: Task<Void, Never>] = [:]

    /// Debounce interval in seconds
    private let debounceInterval: TimeInterval = 1.0

    /// Reference to repository storage for reading current state
    private let storage: InMemoryRepositoryStorage

    public init(storage: InMemoryRepositoryStorage) {
        self.storage = storage
    }

    /// Register writable store files for write-back
    public func register(stores: [StoreFileDescriptor]) {
        for store in stores where store.isWritable {
            writableStores[store.repositoryName] = store.filePath
        }
    }

    /// Mark a repository as dirty and schedule a debounced flush
    public func markDirty(repositoryName: String) {
        guard writableStores[repositoryName] != nil else { return }

        dirtyRepositories.insert(repositoryName)

        // Cancel any pending flush for this repository
        pendingFlush[repositoryName]?.cancel()

        // Schedule a new debounced flush
        let interval = debounceInterval
        pendingFlush[repositoryName] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.flush(repository: repositoryName)
        }
    }

    /// Flush a single repository to its .store file
    private func flush(repository: String) {
        guard let filePath = writableStores[repository] else { return }
        guard dirtyRepositories.contains(repository) else { return }

        // Read current repository contents
        Task {
            let items = await storage.retrieve(from: repository, businessActivity: "store-flush")
            let serialized = FormatSerializer.serialize(items, format: .yaml, variableName: repository)

            // Atomic write: write to .tmp, then rename
            let tmpURL = filePath.appendingPathExtension("tmp")
            do {
                try serialized.write(to: tmpURL, atomically: false, encoding: .utf8)

                // Preserve original file permissions
                let fm = FileManager.default
                #if !os(Windows)
                if let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                   let perms = attrs[.posixPermissions] as? Int {
                    try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmpURL.path)
                }
                #endif

                // Atomic rename (avoid replaceItemAt which is unreliable on Linux)
                try fm.removeItem(at: filePath)
                try fm.moveItem(at: tmpURL, to: filePath)
            } catch {
                // Clean up temp file on failure
                try? FileManager.default.removeItem(at: tmpURL)
            }

            dirtyRepositories.remove(repository)
            pendingFlush.removeValue(forKey: repository)
        }
    }

    /// Flush all dirty writable stores immediately (called during shutdown)
    public func flushAll() async {
        // Cancel all pending debounce timers
        for (_, task) in pendingFlush {
            task.cancel()
        }
        pendingFlush.removeAll()

        // Flush each dirty repository
        for repository in dirtyRepositories {
            guard let filePath = writableStores[repository] else { continue }

            let items = await storage.retrieve(from: repository, businessActivity: "store-flush")
            let serialized = FormatSerializer.serialize(items, format: .yaml, variableName: repository)

            let tmpURL = filePath.appendingPathExtension("tmp")
            do {
                try serialized.write(to: tmpURL, atomically: false, encoding: .utf8)

                #if !os(Windows)
                let fm = FileManager.default
                if let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                   let perms = attrs[.posixPermissions] as? Int {
                    try? fm.setAttributes([.posixPermissions: perms], ofItemAtPath: tmpURL.path)
                }
                #endif

                try FileManager.default.removeItem(at: filePath)
                try FileManager.default.moveItem(at: tmpURL, to: filePath)
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
            }
        }

        dirtyRepositories.removeAll()
    }

    /// Check if a repository is registered as writable
    public func isWritable(repository: String) -> Bool {
        return writableStores[repository] != nil
    }

    /// Get all registered writable repository names
    public var writableRepositoryNames: Set<String> {
        return Set(writableStores.keys)
    }
}
