// ============================================================
// PrepositionCatalog.swift
// AROParser — valid prepositions per action verb
// ============================================================
//
// Prepositions carry semantic weight in ARO: they are what distinguishes
// `Compare … against` from `Compare … with`, and every action declares its
// accepted set as a static `Set<Preposition>`. That constraint is fully
// decidable from the AST, but nothing checked it — so a one-word mistake
// compiled clean and failed at run time with a message that did not mention
// the preposition, the actual cause (GitLab #479):
//
//     Exec the <r> from the <command: "echo hi">.   // 'from' is not valid
//
//     $ aro check .      -> no error
//     $ aro run .        -> "Cannot exec the r from the command: echo hi."
//
// The user reads that as "the command failed" and goes looking at `echo`, when
// the fix is `from` -> `for`.
//
// AROParser cannot import ARORuntime (the dependency runs the other way), so
// this table mirrors the runtime's `validPrepositions` declarations, exactly as
// `ActionCatalog` mirrors their `verbs`. `PrepositionCatalogParityTests` on the
// runtime side asserts the two agree, so the mirror cannot drift silently.
//
// **Generated from the runtime's action declarations.** When you change an
// action's `validPrepositions`, update the matching entry here; the parity test
// will tell you if you forget.
//
// Two aliases declared in `ServerActions.swift` are resolved to their targets
// when generating this table: `Preposition.in` is `.into` and
// `Preposition.through` is `.via`. They are aliases, not cases — the lexer has
// no `in` or `through` token — so `Store the <x> in the <repo>.` does not
// actually parse, even though StoreAction's declaration reads `[.into, .to, .in]`.
// See GitLab #480 for reconciling that with ARO-0004, which documents `in`.

import Foundation

/// Valid prepositions for each built-in action verb, keyed by lowercase verb.
public enum PrepositionCatalog {

    /// Verb -> accepted prepositions.
    ///
    /// Three verbs are claimed by more than one action (`parse`, `map`, `clear`).
    /// The registry resolves those by registration order, which this table cannot
    /// know, so those entries hold the **union** of both actions' sets. Being
    /// permissive is the right failure direction: rejecting valid code is far
    /// worse than missing one invalid spelling, and the runtime still reports it.
    public static let prepositionsByVerb: [String: Set<Preposition>] = [
        "accept": [.on],
        "aggregate": [.from, .with],
        "alert": [.`for`, .to, .with],
        "append": [.into, .to],
        "arrange": [.`for`, .with],
        "ask": [.from, .with],
        "assert": [.`for`, .with],
        "await": [.`for`, .on, .to],
        "block": [.`for`],
        "broadcast": [.to, .via],
        "build": [.`for`, .from, .to, .with],
        "calculate": [.`for`, .from, .with],
        "call": [.from, .to, .via, .with],
        "change": [.`for`, .from, .to, .with],
        "check": [.against, .`for`, .with],
        "checkout": [.from, .to, .with],
        "choose": [.from, .with],
        "clear": [.`for`, .from],  // union: ClearAction + DeleteAction
        "clone": [.from, .to, .with],
        "close": [.from, .with],
        "combine": [.from, .with],
        "commit": [.to, .with],
        "compare": [.against, .to, .with],
        "compute": [.`for`, .from, .with],
        "configure": [.`for`, .from, .to, .with],
        "connect": [.to, .with],
        "construct": [.`for`, .from, .to, .with],
        "convert": [.from, .into, .to],
        "copy": [.to],
        "create": [.`for`, .from, .to, .with],
        "createdirectory": [.at, .`for`, .to],
        "debug": [.`for`, .to, .with],
        "delay": [.`for`, .with],
        "delete": [.`for`, .from],
        "derive": [.`for`, .from, .with],
        "destroy": [.`for`, .from],
        "disconnect": [.from, .with],
        "dispatch": [.to, .via, .with],
        "embed": [.from, .with],
        "emit": [.to, .with],
        "exec": [.`for`, .on, .with],
        "execute": [.`for`, .on, .with],
        "exists": [.`for`],
        "export": [.with],
        "expose": [.with],
        "extract": [.from, .via],
        "fail": [.`for`],
        "fetch": [.from],
        "filter": [.from],
        "find": [.from],
        "get": [.from, .via],
        "given": [.with],
        "group": [.from],
        "http": [.from, .to, .via, .with],
        "include": [.from, .with],
        "insert": [.from, .with],
        "invoke": [.from, .to, .via, .with],
        "join": [.from],
        "keepalive": [.`for`],
        "list": [.from],
        "listen": [.`for`, .on, .to],
        "load": [.from],
        "log": [.`for`, .to, .with],
        "make": [.at, .`for`, .to],
        "map": [.from, .into, .to],  // union: MapAction + TransformAction
        "match": [.against, .to, .with],
        "merge": [.from, .with],
        "mkdir": [.at, .`for`, .to],
        "modify": [.`for`, .from, .to, .with],
        "move": [.to],
        "notify": [.`for`, .to, .with],
        "order": [.`for`, .with],
        "output": [.`for`, .to, .with],
        "parse": [.from, .via],  // union: ExtractAction + ParseLinkHeaderAction
        "parsehtml": [.from],
        "patch": [.at, .to],
        "pause": [.`for`, .with],
        "persist": [.into, .to],
        "print": [.`for`, .to, .with],
        "probe": [.from, .with],
        "prompt": [.from, .with],
        "publish": [.with],
        "pull": [.from],
        "push": [.to, .with],
        "raise": [.`for`],
        "read": [.from],
        "receive": [.from, .via],
        "reduce": [.from, .with],
        "remove": [.`for`, .from],
        "rename": [.to],
        "render": [.to],
        "repaint": [.at, .to],
        "request": [.from, .to, .via, .with],
        "respond": [.`for`, .to, .with],
        "retrieve": [.from],
        "return": [.`for`, .to, .with],
        "run": [.`for`, .on, .with],
        "save": [.into, .to],
        "schedule": [.with],
        "select": [.from, .with],
        "send": [.to, .via, .with],
        "set": [.`for`, .from, .to, .with],
        "share": [.with],
        "shell": [.`for`, .on, .with],
        "show": [.`for`],
        "signal": [.`for`, .to, .with],
        "sleep": [.`for`, .with],
        "sort": [.`for`, .with],
        "split": [.from],
        "stage": [.`for`, .to],
        "start": [.with],
        "stat": [.`for`],
        "stop": [.with],
        "store": [.into, .to],
        "stream": [.from, .with],
        "subscribe": [.from, .with],
        "tag": [.`for`, .with],
        "terminate": [.from, .with],
        "then": [.with],
        "throw": [.`for`],
        "touch": [.at, .`for`, .to],
        "transform": [.from, .into, .to],
        "update": [.`for`, .from, .to, .with],
        "validate": [.against, .`for`, .with],
        "verify": [.against, .`for`, .with],
        "wait": [.`for`],
        "when": [.from],
        "write": [.into, .to],
    ]

    /// The prepositions `verb` accepts, or nil if the verb is not a built-in.
    ///
    /// Returns nil for plugin and user-defined actions, whose prepositions are
    /// only known at run time — callers must treat nil as "cannot check".
    public static func prepositions(forVerb verb: String) -> Set<Preposition>? {
        prepositionsByVerb[verb.lowercased()]
    }

    /// Whether `preposition` is valid for `verb`.
    ///
    /// Unknown verbs return true, so an unrecognised action is never reported as
    /// a preposition error — that is `ActionCatalog`'s job to diagnose.
    public static func isValid(preposition: Preposition, forVerb verb: String) -> Bool {
        guard let accepted = prepositions(forVerb: verb) else { return true }
        return accepted.contains(preposition)
    }

    /// Accepted prepositions for `verb`, sorted for a stable hint message.
    public static func hintList(forVerb verb: String) -> String {
        guard let accepted = prepositions(forVerb: verb) else { return "" }
        return accepted.map(\.rawValue).sorted().joined(separator: ", ")
    }
}
