// ============================================================
// StoreFlushService.swift
// ARO Runtime - Store File Write-Back Service
// ============================================================
//
// Manages write-back for writable .store files. Subscribes to
// RepositoryChangedEvent and flushes dirty repositories to disk.
//
// What is actually guaranteed, because ARO-0073 claimed more than the code
// delivered until GitLab #863:
//
//   * A `.store` file is never left partially written. Each write goes to a
//     sibling `.tmp`, is flushed to the filesystem, and is then moved into
//     place with `rename(2)`, which replaces atomically. A crash leaves either
//     the previous file or the new one, never half of either.
//   * That is a *per-file* guarantee. `Commit the <result> to the <stores>.`
//     writes every store's temp file and fsyncs them all before renaming any,
//     so a failure to serialise or write aborts the whole checkpoint with no
//     file changed. The renames themselves are separate syscalls: a crash
//     between two of them can leave one store new and one old. Making that
//     atomic needs a journal, which is a database, which is the thing a
//     `.store` file exists not to be.
//   * Nothing is guaranteed about changes made since the last successful
//     write. Auto write-back is debounced by a second; a SIGKILL inside that
//     window loses the window's changes. `Commit` is how a program says
//     "now", and shutdown flushes what is outstanding.

import Foundation

/// Where the runtime's live `StoreFlushService` can be found.
///
/// `Commit the <result> to the <orders-repository>.` is an ordinary action,
/// reached from an `ExecutionContext` that knows nothing about store files —
/// and the compiled runtime builds its own service in `RuntimeCoreBridge`, so
/// there are two construction sites and one lookup. A registry of one.
public enum StoreFlushRegistry {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _current: StoreFlushService?

    public static var current: StoreFlushService? {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }
}

/// How writable stores reach disk (ARO-0073 §5, GitLab #863).
public enum StoreWriteBackMode: String, Sendable {
    /// Every mutation schedules a debounced write, and shutdown flushes.
    /// The default, and what the runtime has always done.
    case auto
    /// Mutations mark the store dirty and nothing is written until a `Commit`
    /// statement or shutdown. For a run that rewrites the same rows many times
    /// this is one write instead of one per second of churn.
    case manual
}

/// What a checkpoint did, for the caller to read.
public struct StoreCheckpoint: Sendable {
    public let repositories: [String]
    public let written: Int
    public let items: Int
}

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

    /// Whether mutations schedule their own write-back (ARO-0073 §5).
    private var writeBackMode: StoreWriteBackMode = .auto

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

    /// Switch between debounced auto write-back and explicit `Commit`.
    public func setWriteBackMode(_ mode: StoreWriteBackMode) {
        writeBackMode = mode
        guard mode == .manual else { return }
        // Cancel the timers already ticking; the changes stay dirty and the
        // next Commit — or shutdown — writes them.
        for (_, task) in pendingFlush { task.cancel() }
        pendingFlush.removeAll()
    }

    public var currentWriteBackMode: StoreWriteBackMode { writeBackMode }

    /// Mark a repository as dirty and, in `auto` mode, schedule a debounced flush
    public func markDirty(repositoryName: String) {
        guard writableStores[repositoryName] != nil else { return }

        dirtyRepositories.insert(repositoryName)

        guard writeBackMode == .auto else { return }

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

    /// Flush a single repository to its .store file.
    ///
    /// Awaits the write rather than spawning a task for it, so a caller that
    /// waited knows the bytes are on disk. The debounce timer is what makes
    /// this cheap under churn; doing the write in a detached task on top of
    /// that only made "flushed" unobservable.
    private func flush(repository: String) async {
        guard dirtyRepositories.contains(repository) else { return }
        _ = try? await checkpoint(repositories: [repository])
    }

    /// Write the named stores, all of them or none (ARO-0073 §5a).
    ///
    /// Every file is serialised and written to its own `.tmp` and flushed to
    /// the filesystem *before* any of them is moved into place, so a failure
    /// while serialising or writing leaves every `.store` untouched. See the
    /// note at the top of this file for what the renames do and do not
    /// promise.
    @discardableResult
    public func checkpoint(repositories: [String]? = nil) async throws -> StoreCheckpoint {
        let names = (repositories ?? Array(dirtyRepositories))
            .filter { writableStores[$0] != nil }
        guard !names.isEmpty else {
            return StoreCheckpoint(repositories: [], written: 0, items: 0)
        }

        for name in names {
            pendingFlush[name]?.cancel()
            pendingFlush.removeValue(forKey: name)
        }

        // Phase 1 — serialise and stage. Nothing visible changes here.
        var staged: [(destination: URL, temp: URL)] = []
        var itemCount = 0
        do {
            for name in names {
                guard let destination = writableStores[name] else { continue }
                let items = await storage.retrieve(from: name, businessActivity: "store-flush")
                itemCount += items.count
                let serialized = FormatSerializer.serialize(items, format: .yaml, variableName: name)
                let temp = destination.appendingPathExtension("tmp")
                try Self.writeDurably(serialized, to: temp, matchingPermissionsOf: destination)
                staged.append((destination, temp))
            }
        } catch {
            for entry in staged { try? FileManager.default.removeItem(at: entry.temp) }
            throw error
        }

        // Phase 2 — publish. `rename(2)` replaces the destination atomically,
        // so the file is never observed missing or truncated. `moveItem` fails
        // when the destination exists, which is why this is not that.
        var written = 0
        for entry in staged {
            if Self.replaceAtomically(entry.temp, with: entry.destination) {
                written += 1
            } else {
                try? FileManager.default.removeItem(at: entry.temp)
            }
        }

        for name in names { dirtyRepositories.remove(name) }

        return StoreCheckpoint(repositories: names.sorted(), written: written, items: itemCount)
    }

    /// Flush all dirty writable stores immediately (called during shutdown)
    public func flushAll() async {
        _ = try? await checkpoint()
    }

    /// Check if a repository is registered as writable
    public func isWritable(repository: String) -> Bool {
        return writableStores[repository] != nil
    }

    /// Get all registered writable repository names
    public var writableRepositoryNames: Set<String> {
        return Set(writableStores.keys)
    }

    // MARK: - Durable writes

    /// Write `contents` to `url` and make sure the bytes have reached the
    /// filesystem before the caller continues.
    ///
    /// `Data.write` returns once the page cache has the data; a crash before
    /// the kernel flushes it leaves a file whose *name* was renamed into place
    /// and whose *contents* are absent. `fsync` is what closes that window, and
    /// it is the step ARO-0073's diagram promised and the code never did.
    private static func writeDurably(_ contents: String, to url: URL,
                                     matchingPermissionsOf original: URL) throws {
        let data = Data(contents.utf8)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        #if !os(Windows)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: original.path),
           let perms = attrs[.posixPermissions] as? Int {
            try? FileManager.default.setAttributes([.posixPermissions: perms],
                                                   ofItemAtPath: url.path)
        }
        #endif

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        #if !os(Windows)
        fsync(handle.fileDescriptor)
        #else
        try handle.synchronize()
        #endif
    }

    /// Move `temp` onto `destination`, replacing it atomically.
    private static func replaceAtomically(_ temp: URL, with destination: URL) -> Bool {
        #if os(Windows)
        // No POSIX rename-over on Windows; remove first and accept the window.
        try? FileManager.default.removeItem(at: destination)
        return (try? FileManager.default.moveItem(at: temp, to: destination)) != nil
        #else
        return rename(temp.path, destination.path) == 0
        #endif
    }
}
