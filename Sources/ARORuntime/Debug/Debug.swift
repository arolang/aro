// ============================================================
// Debug.swift
// ARO Runtime - Debugger Task-Local Holder
// ============================================================
//
// The runtime reaches the active debug controller through this
// `TaskLocal`. The CLI `debug` subcommand sets it once with
// `Debug.$controller.withValue(c) { try await app.run() }`; the runtime's
// statement hook reads it. When no debugger is attached the lookup is a
// thread-local pointer load — cheap enough that the production hot path
// pays effectively nothing.

import Foundation

public enum Debug {
    /// Active debug controller for the current Swift Task tree. `nil`
    /// when no debugger is attached.
    @TaskLocal public static var controller: DebugController? = nil

    /// Source-file basename for the feature set currently being executed.
    /// Set by `Application` (or any harness that knows the per-feature-set
    /// source path) right before invoking the executor. Empty string means
    /// "unknown" — breakpoints set by line number alone still work; those
    /// keyed to a file will not match.
    @TaskLocal public static var currentSourceFile: String = ""
}
