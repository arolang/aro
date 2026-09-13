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
    ///
    /// Prefer `sourceFile(forFeatureSet:)`: this is the whole-session
    /// fallback, and a multi-file application needs the per-feature-set
    /// answer.
    @TaskLocal public static var currentSourceFile: String = ""

    /// Feature-set name → source-file basename, for the application being
    /// debugged.
    ///
    /// `currentSourceFile` alone cannot describe a multi-file application:
    /// the CLI set it once, to the *first* source file, so every statement in
    /// every file reported `main.aro`. A breakpoint on `orders.aro:12` could
    /// then never match, and `b 12` — which is documented as picking up the
    /// file of the current pause — picked up the wrong one (GitLab #555).
    ///
    /// The harness that compiles the application knows which file each
    /// feature set came from, and fills this in before running. Empty ⇒ fall
    /// back to `currentSourceFile`, so harnesses that do not set it behave
    /// exactly as before.
    @TaskLocal public static var sourceFileIndex: [String: String] = [:]

    /// The source file to attribute `featureSetName`'s statements to.
    public static func sourceFile(forFeatureSet featureSetName: String) -> String {
        sourceFileIndex[featureSetName] ?? currentSourceFile
    }
}
