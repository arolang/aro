// ============================================================
// SystemObjectCatalog.swift
// AROParser — shared catalog of framework-provided object names
// ============================================================
//
// Single source of truth for the object bases that are provided by
// the framework rather than defined by user code. Consulted by:
//
//   - `DataFlowAnalyzer` to decide whether an object reference is a
//     forward reference to an undefined variable (a real warning) or
//     a system object the runtime supplies (not a warning).
//
// This list used to be an inline literal inside `DataFlowAnalyzer`.
// It drifted from the runtime every time a system object was added,
// producing "used before definition" warnings on correct,
// spec-compliant code — `<command: …>`, `<url: …>` and
// `<destination: …>` were all missing (GitLab #478). Noise like that
// trains users to ignore `aro check`, which then hides real findings.
//
// AROParser cannot import ARORuntime (the dependency runs the other
// way), so the catalog lives here alongside `ActionCatalog`, which
// exists for the same reason. **Adding a system object to the runtime
// requires adding its qualifier base here.** The parser tests in
// `SystemObjectCatalogTests` check that every name in this catalog
// survives `aro check` without a warning.

import Foundation

/// Object bases the framework provides, which therefore never need a
/// preceding definition in user code.
public enum SystemObjectCatalog {

    /// Bases that name a framework-provided object.
    ///
    /// Grouped by the subsystem that supplies them. Each entry corresponds to a
    /// base the runtime special-cases (an `object.base == "…"` check, an
    /// `excluding:` set in a file action, or a registered `SystemObject`).
    public static let names: Set<String> = [
        // HTTP request/response surface
        "request", "incoming-request", "context", "session",
        "pathparameters", "queryparameters", "headers",

        // Application lifecycle
        "console", "application", "event", "shutdown", "events", "contract",

        // Networking
        "port", "host",
        "url",              // ARO-0052 unified URL I/O: <url: "https://…">

        // Filesystem — mirrors the `excluding:` sets in FileActions
        "directory", "file", "path",
        "destination",      // ARO-0036 Copy/Move: to the <destination: target>

        // Templates
        "template",

        // Repositories (also matched by the `-repository` suffix rule below)
        "repository",

        // Framework-provided runtime objects
        "terminal",         // terminal I/O target for Prompt / Clear / Show / Render
        "env",              // process environment via `<env: NAME>` / `<env>`
        "git",              // embedded git system object (ARO-0080)
        "parameter",        // CLI arguments via `<parameter: name>` / `<parameter>`
        "input",            // user-defined action arguments via `<input: name>`
        "command",          // Exec target: for the <command: "uptime">

        // Parser-synthesised bases for literal and expression operands
        "_literal_",
        "_expression_"
    ]

    /// Whether `name` refers to a framework-provided object.
    ///
    /// Case-insensitive, and treats any `*-repository` name as provided, since
    /// repositories are created on first use rather than declared.
    public static func isSystemObject(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasSuffix("-repository") { return true }
        return names.contains(lower)
    }
}
