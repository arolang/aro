// ============================================================
// EditorSaveState.swift
// SOLARO — disk-write health of the open editor buffers
// ============================================================
//
// SOLARO's save model is per-keystroke autosave: there is no dirty
// indicator and no ⌘S the user can retry, so a failed write is
// invisible. Every editor write used to be `try? … .write(to:)`,
// and the caller then updated `fileText`, `liveEditorText`, the LSP
// and the parse cache as if it had succeeded. On a read-only file
// (checked-out artifact, wrong permissions, read-only volume, full
// disk) the editor accepted every keystroke and the file on disk
// never changed — the "saved" edits evaporated when the tab closed
// (GitLab #532).
//
// This is the state machine behind the fix. `WorkspaceController`
// owns one instance, routes every write through it, and the center
// pane renders a banner while any failure stands. It is pure and
// value-typed so the whole non-visual half is testable headlessly.

import Foundation

/// Per-file record of whether the last write to disk succeeded.
struct EditorSaveState: Equatable {

    /// A standing write failure for one file.
    struct Failure: Equatable {
        /// Human-readable reason, taken from the underlying error.
        var message: String
        /// When the *first* failure in this run started. Kept stable
        /// across retries so the banner doesn't reset its wording on
        /// every keystroke.
        var firstFailedAt: Date
        /// How many writes have failed since then. Every keystroke
        /// retries, so this climbs fast — it exists to keep the
        /// stderr log quiet, not to be shown verbatim.
        var attempts: Int
    }

    private(set) var failures: [URL: Failure] = [:]

    init() {}

    /// Standing failure for `url`, if the last write didn't land.
    func failure(for url: URL) -> Failure? {
        failures[url.standardizedFileURL]
    }

    var hasFailures: Bool { !failures.isEmpty }

    /// Record a successful write. Returns true when this cleared a
    /// standing failure — i.e. the banner should come down.
    @discardableResult
    mutating func recordSuccess(for url: URL) -> Bool {
        failures.removeValue(forKey: url.standardizedFileURL) != nil
    }

    /// Record a failed write. Returns true when the caller should
    /// surface this *loudly* (log to stderr): the first failure for
    /// the file, or a failure whose reason changed. Subsequent
    /// identical failures return false — autosave retries on every
    /// keystroke, and one line per keystroke would bury the log.
    @discardableResult
    mutating func recordFailure(for url: URL,
                                message: String,
                                now: Date = Date()) -> Bool {
        let key = url.standardizedFileURL
        if var existing = failures[key] {
            existing.attempts += 1
            let changed = existing.message != message
            existing.message = message
            failures[key] = existing
            return changed
        }
        failures[key] = Failure(message: message,
                                firstFailedAt: now,
                                attempts: 1)
        return true
    }

    /// Drop a file's record entirely — used when its tab closes, so
    /// a stale banner can't follow the user to the next file.
    mutating func forget(_ url: URL) {
        failures.removeValue(forKey: url.standardizedFileURL)
    }

    /// One-line banner text for a standing failure.
    static func bannerMessage(fileName: String, failure: Failure) -> String {
        "Couldn't save \(fileName): \(failure.message) — your edits are only in memory."
    }
}
