// ============================================================
// ExternalFileWatcher.swift
// SOLARO — noticing that the world changed under the editor
// ============================================================
//
// SOLARO used to watch exactly one file for external changes:
// `openapi.yaml`. Everything else refreshed only when the AI
// co-pilot announced its own writes, or when `load()` ran — which
// happened on workspace appear and after New File, and nowhere
// else (GitLab #536).
//
// For an autosave-based editor that is not a missing nicety, it is
// a working-tree hazard: after a `git checkout` the open buffers
// still held the old text, and the next keystroke autosaved that
// stale buffer straight over the new checkout.
//
// Two pieces live here: the decision (pure, tested) and the kqueue
// plumbing that feeds it.

import Foundation

/// What to do about a file that changed on disk behind the editor.
enum ExternalChangeOutcome: Equatable {
    /// Disk already matches the buffer — typically our own autosave
    /// coming back around. Do nothing.
    case inSync
    /// The buffer has no unsaved work, so taking the disk version
    /// loses nothing.
    case reload
    /// The buffer and disk have both moved on. The user has to pick,
    /// and until they do we must not autosave over the file.
    case conflict
}

enum ExternalChangePolicy {

    /// Decide what an external write means for one open file.
    ///
    /// - Parameters:
    ///   - buffer: the live editor buffer, or nil when the file has
    ///     no open editor.
    ///   - lastSaved: the text SOLARO last successfully wrote (or
    ///     read at load). This is what makes "does the buffer have
    ///     unsaved work?" answerable at all under autosave, where the
    ///     buffer normally equals disk after every keystroke.
    ///   - disk: the file's current contents.
    static func outcome(buffer: String?,
                        lastSaved: String?,
                        disk: String) -> ExternalChangeOutcome {
        // Nothing open: whatever is on disk is simply the truth.
        guard let buffer else { return .reload }
        if buffer == disk { return .inSync }
        // Buffer matches what we last put on disk ⇒ every edit the
        // user made is already saved, so the difference is entirely
        // the external write's doing.
        if let lastSaved, buffer == lastSaved { return .reload }
        // Either we never established a baseline, or the buffer holds
        // work that never reached disk (a failed save, GitLab #532).
        // Both mean: don't decide for the user.
        return .conflict
    }
}

/// Watches a set of files (and directories) for external writes and
/// calls back on the main actor, coalesced.
///
/// kqueue rather than FSEvents: the set is small (open tabs plus the
/// project root), and `DispatchSourceFileSystemObject` is already
/// what `OpenAPIDocument` uses, so there is one mechanism in the app
/// rather than two.
@MainActor
final class ExternalFileWatcher {

    /// Fired with the changed path after the debounce window.
    var onChange: ((URL) -> Void)?

    private struct Entry {
        let source: DispatchSourceFileSystemObject
        let descriptor: Int32
    }

    private var entries: [URL: Entry] = [:]
    private var pending: Set<URL> = []
    private var flushTask: Task<Void, Never>?

    /// Coalescing window. A single `git checkout` rewrites many files
    /// in a burst, and an atomic save is a rename storm of its own.
    private let debounce: Duration

    init(debounce: Duration = .milliseconds(200)) {
        self.debounce = debounce
    }

    deinit {
        // Sources are cancelled from `stop()`; this is the safety net
        // for a watcher dropped without one. `cancel()` is safe to
        // call from any thread and the cancel handler closes the fd.
        for entry in entries.values {
            entry.source.cancel()
        }
    }

    /// Replace the watched set. Paths already watched keep their
    /// existing source, so re-syncing on every tab change doesn't
    /// churn descriptors.
    func watch(_ urls: [URL]) {
        let wanted = Set(urls.map(\.standardizedFileURL))
        for (url, entry) in entries where !wanted.contains(url) {
            entry.source.cancel()
            entries.removeValue(forKey: url)
        }
        for url in wanted where entries[url] == nil {
            install(url)
        }
    }

    /// Stop watching everything and cancel any pending callback.
    func stop() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        for entry in entries.values {
            entry.source.cancel()
        }
        entries.removeAll()
    }

    var watchedCount: Int { entries.count }

    private func install(_ url: URL) {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let flags = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                self.note(url)
                // A delete/rename means the inode we're holding is
                // gone — which is exactly what an atomic save or a
                // `git checkout` does. Re-arm on the path so the
                // NEXT external write is seen too; without this the
                // watcher goes deaf after one change.
                if flags.contains(.delete) || flags.contains(.rename) {
                    self.reinstall(url)
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        entries[url] = Entry(source: source, descriptor: fd)
    }

    private func reinstall(_ url: URL) {
        guard let entry = entries.removeValue(forKey: url) else { return }
        entry.source.cancel()
        // Give the replacement file a moment to land before re-opening
        // the path — an atomic write is unlink+rename, so the path can
        // be briefly absent.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, self.entries[url] == nil else { return }
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            self.install(url)
        }
    }

    private func note(_ url: URL) {
        pending.insert(url)
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            let batch = self.pending
            self.pending.removeAll()
            self.flushTask = nil
            for url in batch {
                self.onChange?(url)
            }
        }
    }
}
