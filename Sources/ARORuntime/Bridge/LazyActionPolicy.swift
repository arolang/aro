// ============================================================
// LazyActionPolicy.swift
// ARORuntime - Force-at-site policy for lazy action execution (Issue #55, Phase 2)
// ============================================================
//
// Phase 2 design decision (per the issue plan): default to laziness.
// Most actions return an AROFuture; the next action that consumes the
// binding forces it transparently via context.resolveAny.
//
// A small set of verbs are *force-at-site*: they need their inputs
// materialized AND must run synchronously at their statement position
// because they have observable side effects (output, response, error
// propagation) that the rest of the program relies on having happened.
//
// This is intentionally conservative for Phase 2. Phase 3 widens the
// set with branch-condition consumers (Compare-as-branch, When guards)
// and feature-set exit. Adding too few force points yields broken
// effect ordering; adding too many erodes the laziness benefit.

import Foundation

public enum LazyActionPolicy {

    /// Verbs whose action MUST run synchronously at the call site under
    /// lazy mode. Inputs are forced before the action runs; the result
    /// is bound eagerly. Match against canonical verbs (post-canonicalize).
    ///
    /// Phase 2 set:
    ///   - return / throw — control flow / response materialization
    ///   - log            — observable stdout/stderr output
    ///   - publish        — exports a concrete value into GlobalSymbolRegistry
    ///   - emit           — bus delivery; payload force is per-handler
    ///                      but the bridge call itself stays eager so causality
    ///                      with publishAndTrack() handler-wait is preserved
    ///
    /// Phase 3 additions (branch consumers):
    ///   - compare        — boolean output feeds an `if`/`when` branch
    ///   - validate       — boolean output feeds an `if`/`when` branch
    ///   - accept         — state-machine transition; consumed by branch
    public static let forceAtSiteVerbs: Set<String> = [
        // Phase 2 — visible side effects / control flow
        "return",
        "throw",
        "log",
        "publish",
        "emit",
        // Phase 3 — branch consumers
        "compare",
        "validate",
        "accept"
    ]

    /// Returns true if this verb must execute eagerly at its statement
    /// position. The verb is expected to already be canonicalized via
    /// `ActionRunner.canonicalizeVerb(...)`.
    public static func forceAtSite(_ canonicalVerb: String) -> Bool {
        return forceAtSiteVerbs.contains(canonicalVerb)
    }

    // MARK: - Deferral (ARO-0088 §2)

    /// Verbs whose result may be produced concurrently with the statements that
    /// follow it. The statement still *starts* where it is written; only the
    /// wait moves, to the first read of the binding.
    ///
    /// This is an allowlist, not the complement of `forceAtSiteVerbs`, and
    /// deliberately so. Semantic role is too coarse to decide deferability:
    /// `ActionSemanticRole.classify` puts `update` and `delete` in `.own`
    /// alongside `compute`, but deferring a repository delete would move a
    /// world-changing effect to wherever someone happened to read its result.
    /// Everything here either computes a value or reads one; nothing here
    /// changes state that another statement can observe.
    ///
    /// Deliberately absent, with reasons:
    ///   - `sleep`/`delay`/`pause` — the delay *is* the effect. Deferring would
    ///     silently delete the pacing in `Sleep … ` followed by an unrelated
    ///     `Log`.
    ///   - `update`, `delete`, `store`, `send`, `write`, `commit`, `push`,
    ///     `stage`, `tag`, `notify` — observable state changes.
    ///   - `start`, `stop`, `connect`, `close`, `keepalive` — service lifecycle,
    ///     ordered against everything else by definition.
    ///   - `assert`, `then` — a test that runs only if someone reads it is not
    ///     a test.
    ///   - `render`, `repaint` — `ActionSemanticRole.classify` files both under
    ///     `.response`: they paint a terminal. Deferring `render` reordered the
    ///     TerminalSimpleMenu banner ahead of the log lines that precede it.
    public static let deferrableVerbs: Set<String> = [
        // Reads: external -> internal
        "retrieve", "fetch", "read", "request", "load", "find", "probe", "receive",
        "extract", "parse", "get",
        // Pure transformations: internal -> internal
        "compute", "calculate", "derive", "transform", "create", "build", "construct",
        "filter", "map", "reduce", "aggregate", "split", "group", "sort",
        "merge", "combine", "join", "concat", "format"
    ]

    /// Whether this statement's action may run concurrently with the statements
    /// that follow it. Force-at-site always wins: a verb in both sets is eager.
    /// `ARO_NO_DEFER` runs every action at its statement, as the runtime did
    /// before ARO-0088. Kept as an escape hatch: if a program misbehaves in a
    /// way that looks order-related, setting it is the one-step way to find out
    /// whether overlap is involved.
    public static func deferrable(_ canonicalVerb: String) -> Bool {
        if ProcessInfo.processInfo.environment["ARO_NO_DEFER"] != nil { return false }
        return !forceAtSiteVerbs.contains(canonicalVerb) && deferrableVerbs.contains(canonicalVerb)
    }
}
