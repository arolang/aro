// ============================================================
// AROWorkingDirectory.swift
// ARORuntime — where a relative path resolves from (GitLab #758)
// ============================================================
//
// A relative path in an ARO program — `Write the <report> to the
// <file: "output/report.csv">` — means "relative to the application",
// and for `aro run` that is simply the process's working directory,
// because the process exists for that one application.
//
// SOLARO's embedded backend runs the application *inside the IDE*, and
// so it used to call `changeCurrentDirectoryPath` for the duration of
// the run. The working directory is process-global. The run is on a
// detached task and is held for the whole life of the program — which
// for a `Keepalive` service is forever. Meanwhile the main actor keeps
// doing its own relative-path work, and two windows running two
// projects fight over one setting.
//
// So the runtime carries the answer instead of reading it off the
// process. Resolution order:
//
//   1. The task-local, which follows structured concurrency: everything
//      `application.run()` starts, including the HTTP server's child
//      tasks, inherits it. This is the isolating one — two concurrent
//      runs get their own, and the IDE's own work outside the run sees
//      nothing at all.
//   2. The process-wide default, as a net for work that escapes the
//      task tree entirely. A detached task started by a plugin has no
//      task-local to inherit.
//   3. The real working directory, which is the right answer for
//      `aro run` and for every non-embedded caller.
//
// Only (3) applies unless somebody sets the others, so nothing changes
// for the CLI.

import Foundation

/// The directory a relative path in an ARO program resolves against.
public enum AROWorkingDirectory {

    /// Scoped to one run and everything it starts. Prefer this.
    @TaskLocal public static var current: String?

    /// Process-wide fallback for work that escapes the task tree.
    ///
    /// Guarded rather than a bare global because the runtime is
    /// concurrent by construction and this is read from every file
    /// action.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var processDefault: String?

    /// Set the process-wide fallback, returning the previous value so
    /// the caller can restore it.
    @discardableResult
    public static func setProcessDefault(_ path: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let previous = processDefault
        processDefault = path
        return previous
    }

    /// The base directory in effect right here.
    public static var base: String {
        if let scoped = current { return scoped }
        lock.lock()
        let fallback = processDefault
        lock.unlock()
        return fallback ?? FileManager.default.currentDirectoryPath
    }

    /// Resolve `path` the way the process would have, had it been
    /// `chdir`ed into the application.
    ///
    /// Absolute paths and `~` are returned untouched — an ARO program
    /// that names `/tmp/out.csv` means `/tmp/out.csv` wherever it runs.
    public static func resolve(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        if path.isEmpty { return base }
        return (base as NSString).appendingPathComponent(path)
    }

    /// `resolve`, as a URL.
    public static func url(_ path: String) -> URL {
        URL(fileURLWithPath: resolve(path))
    }
}
