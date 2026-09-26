// ============================================================
// PluginBuildProgress.swift
// ARORuntime — say when a plugin is being compiled (GitLab #826)
// ============================================================
//
// `aro run Examples/SQLiteExample` produced nothing for over two minutes on a
// fresh checkout: the runtime was compiling the example's Swift package plugin,
// fetching SQLite.swift and the plugin SDK on the way. Two minutes of silence
// looks like a hang, and it needs network access — neither of which the user
// had any way to know.
//
// The other plugin examples only *look* fast because prebuilt libraries are
// lying in the tree.
//
// Progress goes to stderr, so it stays out of a program's own output and out of
// anything a caller pipes. `ARO_QUIET_PLUGIN_BUILD=1` silences it.

import Foundation

/// Announces a plugin compilation on stderr so a long first run is legible.
public enum PluginBuildProgress {

    /// A build in progress — hold it and call `finished()` / `failed()`.
    public struct Token: Sendable {
        let plugin: String
        let startedAt: Date
        let announced: Bool
    }

    /// Whether progress is printed at all.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["ARO_QUIET_PLUGIN_BUILD"] != "1"
    }

    /// Announce that `plugin` is about to be compiled with `command`.
    ///
    /// - Parameter firstRun: whether to add the one-time-cost note. True for
    ///   package builds, which resolve and fetch dependencies; a single-file
    ///   `swiftc` takes a second and needs no warning.
    @discardableResult
    public static func started(
        plugin: String,
        command: String,
        firstRun: Bool = true
    ) -> Token {
        guard isEnabled else {
            return Token(plugin: plugin, startedAt: Date(), announced: false)
        }
        var line = "[aro] Building plugin '\(plugin)' (\(command))…"
        if firstRun {
            line += " first run only; it may take a few minutes and needs network access."
        }
        write(line)
        return Token(plugin: plugin, startedAt: Date(), announced: true)
    }

    /// Report that the build finished, with how long it took.
    public static func finished(_ token: Token) {
        guard token.announced else { return }
        write("[aro] Built plugin '\(token.plugin)' in \(elapsed(token)).")
    }

    /// Report that the build failed. The caller still throws; this only makes
    /// sure the elapsed time isn't lost in a stack of compiler output.
    public static func failed(_ token: Token) {
        guard token.announced else { return }
        write("[aro] Building plugin '\(token.plugin)' failed after \(elapsed(token)).")
    }

    // MARK: - Private

    private static func elapsed(_ token: Token) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(token.startedAt))
    }

    // MARK: - Test seam

    // Tests used to capture this by `dup2`-ing fd 2 to a temp file. That is a
    // *process-global* change, and the test suite runs hundreds of suites in
    // parallel — so it intermittently stole stderr from unrelated tests and
    // crashed one inside `FileHandle.readDataUpToLength`. A sink they can
    // substitute costs one indirection and cannot affect anyone else.
    private static let sinkLock = NSLock()
    nonisolated(unsafe) private static var testSink: (@Sendable (String) -> Void)?

    /// Redirect progress lines, for tests. `nil` restores stderr.
    static func setSinkForTesting(_ sink: (@Sendable (String) -> Void)?) {
        sinkLock.lock()
        defer { sinkLock.unlock() }
        testSink = sink
    }

    private static func write(_ line: String) {
        sinkLock.lock()
        let sink = testSink
        sinkLock.unlock()

        if let sink {
            sink(line)
        } else {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    }
}
