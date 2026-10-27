// ============================================================
// AROTruthiness.swift
// ARO Runtime — one rule for what counts as true
// GitLab #644
// ============================================================
//
// There were five. `FeatureSetExecutor.asBool` treated a non-empty string or
// array as true and anything unrecognised as true; `ExpressionEvaluator`'s
// copy did the same for `and`/`or`/`not`; two sites in `ExecutionEngine`
// treated a non-Bool as false; `EventHandlerDependencies` asked whether
// `String(describing:)` was non-empty, which `false` passes; and the match
// guard accepted a `Bool` and nothing else.
//
// So the same condition could be true in a statement guard and false in a
// handler guard, and a guard written against a compiled binary's 0/1 could
// fail in one place and pass in another. One rule, in one file.

import Foundation

public enum AROTruthiness {

    /// The value as a condition, or `nil` when it is not one.
    ///
    /// ARO-0002: *"Guard Evaluation: Conditions must be boolean
    /// expressions."* So a string is not a condition, however non-empty, and
    /// neither is a record.
    ///
    /// `Int` is a condition because `0`/`1` is how a compiled binary and
    /// several bridges carry a boolean across the C ABI. Dropping it would
    /// break the two execution modes against each other rather than align
    /// them, which is the whole point of this file.
    ///
    /// `nil` rather than `false`, so each caller decides what absence means:
    /// a statement guard has a statement to name in an error, a subscription
    /// closure has only stderr.
    public static func strict(_ value: any Sendable) -> Bool? {
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        return nil
    }
}
