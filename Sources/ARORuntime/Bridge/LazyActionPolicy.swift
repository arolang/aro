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
}
