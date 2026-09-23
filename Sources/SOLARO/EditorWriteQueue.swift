// ============================================================
// EditorWriteQueue.swift
// SOLARO — one disk write per pause, not one per keystroke (#748)
// ============================================================
//
// The editor's binding setter fires for every character. It used to call
// `writeToDisk` straight away — an atomic whole-file write, so a temp file, a
// rename and a permissions fix-up per keystroke. The rename is what hurts
// twice: `ExternalFileWatcher` re-installs its kqueue on every `.rename`, and
// `GitStatusMonitor` was refreshed right behind it, defeating its own
// five-second cache.
//
// So writes are coalesced here. The buffer the user sees is still updated
// synchronously — `liveEditorText`, the parsed program, the canvas — only the
// bytes on disk lag, and only until the typing stops.
//
// Two rules keep that lag honest:
//
//   * A burst never postpones the write indefinitely. The debounce re-arms
//     per keystroke, but `maximumDelay` since the *first* unwritten change is
//     a hard ceiling: hold a key down and the file is still saved every two
//     seconds.
//   * Anything that reads the file from somewhere other than the buffer
//     flushes first. `aro run`, `aro test`, a commit, switching files, the app
//     losing focus — each calls `flush()` before it looks at disk, so no
//     subprocess ever sees a stale file.
//
// Each entry carries its own writer closure rather than a reference to one
// controller: two project windows are two `WorkspaceController`s, and a write
// must be recorded against the window whose buffer it came from.

import AppKit
import Foundation

/// Coalesces editor autosaves into one write per pause.
@MainActor
final class EditorWriteQueue {

    static let shared = EditorWriteQueue()

    /// Quiet period after the last keystroke before the write lands.
    static let debounce: Duration = .milliseconds(300)

    /// Longest a change may sit unwritten while the user keeps typing.
    static let maximumDelay: Duration = .seconds(2)

    private struct Entry {
        let text: String
        let queuedAt: ContinuousClock.Instant
        let write: (String, URL) -> Bool
    }

    private var pending: [URL: Entry] = [:]
    private var timer: Task<Void, Never>?

    /// `installsLifecycleFlush: false` builds a queue that is not wired
    /// to the app's lifecycle.
    ///
    /// Only `shared` should install those observers; a test wants its
    /// own queue precisely so that everything else in the process —
    /// another suite's `flush()`, a controller's autosave — cannot
    /// drain it mid-assertion.
    init(installsLifecycleFlush: Bool = true) {
        guard installsLifecycleFlush else { return }
        // Losing focus or quitting must not lose the last few characters.
        // The app-level flush is what makes the debounce safe to widen: an
        // unwritten buffer never survives the app going away.
        for name in [NSApplication.willResignActiveNotification,
                     NSApplication.willTerminateNotification] {
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { EditorWriteQueue.shared.flush() }
            }
        }
    }

    // MARK: - Queueing

    /// Record `text` as the file's next contents and arm the timer.
    ///
    /// Re-queueing the same URL replaces the text but keeps the original
    /// `queuedAt`, so the ceiling is measured from the first change the disk
    /// has not seen — not from the most recent one, which would never expire.
    func enqueue(_ text: String, to url: URL,
                 write: @escaping (String, URL) -> Bool) {
        let key = url.standardizedFileURL
        let queuedAt = pending[key]?.queuedAt ?? ContinuousClock.now
        pending[key] = Entry(text: text, queuedAt: queuedAt, write: write)

        if ContinuousClock.now - queuedAt >= Self.maximumDelay {
            flush()
            return
        }

        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// The text queued for `url`, if a write is still outstanding.
    ///
    /// Readers that would otherwise hit disk consult this first, so a file
    /// mid-debounce still reads back as what the user typed.
    func pendingText(for url: URL) -> String? {
        pending[url.standardizedFileURL]?.text
    }

    var hasPendingWrites: Bool { !pending.isEmpty }

    /// Drop the queued write for `url` without performing it.
    ///
    /// For the caller that is about to write the same file itself — an
    /// explicit save, which also formats — so the debounced copy cannot land
    /// afterwards and undo the formatting.
    func cancel(_ url: URL) {
        pending.removeValue(forKey: url.standardizedFileURL)
        if pending.isEmpty { timer?.cancel(); timer = nil }
    }

    // MARK: - Flushing

    /// Perform every outstanding write now. Safe to call when empty.
    ///
    /// Call this before anything reads the project from disk rather than from
    /// the editor buffer.
    @discardableResult
    func flush() -> Int {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return 0 }
        let batch = pending
        pending = [:]
        for (url, entry) in batch {
            _ = entry.write(entry.text, url)
        }
        return batch.count
    }

    /// `flush()` for call sites that only need the side effect.
    static func flushNow() { shared.flush() }
}
