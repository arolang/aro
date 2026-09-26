// ============================================================
// ActionRoleCatalog.swift
// AROParser — one definition of the action role taxonomy (GitLab #585)
// ============================================================
//
// Every action has a semantic role (REQUEST / OWN / RESPONSE / EXPORT /
// SERVER), and it used to be defined *twice*:
//
//   * `ActionSemanticRole.classify(verb:)` — four hardcoded verb lists, used
//     by the parser and everything downstream of the AST. The LSP hover panel
//     prints this one.
//   * `ActionImplementation.role` on each action type — what the registry
//     knows, and what `aro actions` prints.
//
// They disagreed on 25 of the 136 registered verbs. Hover over `Emit` in
// SOLARO and it said **response**; `aro actions` said **export**. Most of the
// rest differed because `classify` had no entry for the verb at all and fell
// through to `.own`, so it was never simply a stale copy — `ask`, `clone`,
// `exists`, `find`, `probe`, `pull`, `stat`, `commit`, `push`, `tag`,
// `append`, `dispatch`, `fail` and `raise` were all mis-reported.
//
// This is the one table. The registry stays the source of truth in spirit —
// it lives next to each action, `aro actions` and ARO-0004 §11 publish it, and
// plugins supply their own role there — but AROParser cannot import ARORuntime,
// so the table is mirrored here and `ActionRoleCatalogParityTests` asserts the
// two agree for every registered verb. That is the arrangement
// `ComputeQualifierCatalog` and `ComputeAction.builtInQualifiers` already use:
// add a verb to one and the suite fails until you add it to the other.

import Foundation

/// Verb → semantic role, mirroring `ActionImplementation.role`.
public enum ActionRoleCatalog {

    /// Roles for every built-in verb, keyed by the lowercased verb.
    public static let roles: [String: ActionSemanticRole] = {
        var table: [String: ActionSemanticRole] = [:]
        func add(_ role: ActionSemanticRole, _ verbs: String...) {
            for verb in verbs { table[verb] = role }
        }

        add(.request,
            "ask", "choose", "clone", "exists", "extract", "fetch", "find", "get",
            "http", "list", "load", "parse", "probe", "prompt", "pull", "read",
            "receive", "request", "retrieve", "select", "stat", "stream", "subscribe")

        add(.response,
            "alert", "append", "broadcast", "debug", "dispatch", "fail", "log",
            "notify", "output", "patch", "persist", "print", "raise", "render",
            "repaint", "respond", "return", "save", "send", "signal", "store",
            "throw", "write")

        add(.export,
            "commit", "emit", "export", "expose", "publish", "push", "schedule",
            "share", "tag")

        add(.server,
            "await", "block", "close", "connect", "copy", "createdirectory",
            "disconnect", "keepalive", "listen", "make", "mkdir", "move",
            "rename", "start", "stop", "terminate", "touch", "wait")

        add(.own,
            "accept", "aggregate", "arrange", "assert", "build", "calculate",
            "call", "change", "check", "checkout", "clear", "combine", "compare",
            "compute", "configure", "construct", "convert", "create", "delay",
            "delete", "derive", "destroy", "embed", "exec", "execute", "filter",
            "flip", "given", "group", "include", "insert", "invoke", "join",
            "map", "match", "merge", "modify", "order", "parsehtml", "pause",
            "reduce", "remove", "reverse", "run", "set", "shell", "show", "sleep",
            "sort", "split", "stage", "then", "transform", "update", "validate",
            "verify", "when")

        return table
    }()

    /// The role for `verb`, or `.own` for a verb the catalog does not know.
    ///
    /// `.own` is the right default for an unknown verb: a plugin action the
    /// parser has not seen yet is internal-to-internal as far as data flow is
    /// concerned, and the registry answers for it once loaded.
    public static func role(forVerb verb: String) -> ActionSemanticRole {
        roles[verb.lowercased()] ?? .own
    }

    /// Verbs whose statement must run **for its effect**, even when the value
    /// it would produce is already known, and which therefore bind no result.
    ///
    /// `FeatureSetExecutor` used to ask `semanticRole == .response` for this.
    /// That was the same taxonomy this file unifies, used as a proxy for a
    /// different question — so correcting `emit` from `.response` to `.export`
    /// would have silently stopped an `Emit` re-running after the expression
    /// fast path, and started it binding a result. The issue says as much:
    /// today's behaviour is "correct by accident, from the wrong list".
    ///
    /// So the predicate is now written down as itself. It is exactly the old
    /// `responseVerbs` list, which is what the executor was really asking
    /// about, and it is deliberately *not* derived from the role — an effect
    /// verb can be RESPONSE (`Return`, `Log`) or EXPORT (`Emit`, `Publish`),
    /// and the two questions are not the same one.
    /// `declare` and `attach` (ARO-0094) are here for the same reason the rest
    /// are, and the reason is worth stating because they do not look like
    /// output verbs. `Declare the <cart-repository> with { scope: "session" }.`
    /// takes its argument as an expression, so without this the fast path binds
    /// the map to `<cart-repository>` and never runs the action — the scope is
    /// never registered, and every statement that depends on it silently reads
    /// the application-wide repository instead. The value the statement
    /// produces is beside the point; registering the scope is the statement.
    public static let mustRunForEffect: Set<String> = [
        "return", "throw", "send", "emit", "respond", "output", "write",
        "store", "save", "persist", "log", "print", "debug", "notify",
        "alert", "signal", "broadcast", "render", "repaint", "patch",
        "declare", "attach",
    ]

    /// Whether `verb`'s statement must run for its effect (see
    /// `mustRunForEffect`).
    public static func mustRunForEffect(_ verb: String) -> Bool {
        mustRunForEffect.contains(verb.lowercased())
    }
}
