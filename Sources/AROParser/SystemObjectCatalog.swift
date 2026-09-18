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

    /// System objects that are a **record of values**, not an address.
    ///
    /// The distinction matters for the `default` operator. `<file: "notes.md">`
    /// is an address an action resolves — there is no variable called `file`
    /// for an expression to read, so routing it through the expression grammar
    /// would find nothing and hand back the fallback every time. But
    /// `<queryParameters: limit>` *is* a value the expression evaluator can
    /// read, so a missing `limit` is genuinely absent and `default` should
    /// answer it.
    ///
    /// Without this, `Create the <limit> with <queryParameters: limit> default 10.`
    /// failed the statement when the client omitted `?limit=` — the one case
    /// the fallback exists for (GitLab #590).
    ///
    /// Two exclusions are deliberate. `<request: body>` carries the streaming
    /// semantics of ARO-0090 and is consumed once, so promoting it would
    /// materialise a body just to answer a presence check. And `headers` does
    /// not resolve as a record at all — even `Extract the <h> from the
    /// <headers>.` fails — so `<headers: x> default "y"` would have answered
    /// `"y"` for a header that *was* sent. Both were checked rather than
    /// assumed; the header case was caught exactly this way.
    ///
    /// Everything in this set must be resolvable by *both* evaluators. A base
    /// that only the action path can resolve would silently take the default
    /// on every read, which is the failure #547 was reported for.
    public static let valueBearingNames: Set<String> = [
        "parameter",        // CLI arguments — a missing --port is absent
        "env",              // process environment
        "queryparameters",  // HTTP query string (GitLab #590)
        "pathparameters",   // HTTP path template values
        "input",            // user-defined action arguments (ARO-0081)
        "event",            // event payload fields in a handler
    ]

    /// Whether `<name: field>` may be read as an expression operand, so that
    /// `default` can answer a missing field rather than failing the statement.
    public static func isValueBearing(_ name: String) -> Bool {
        valueBearingNames.contains(name.lowercased())
    }

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
