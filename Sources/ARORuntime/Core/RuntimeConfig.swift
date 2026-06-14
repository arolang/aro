// ============================================================
// RuntimeConfig.swift
// ARO Runtime - Centralised default constants
// ============================================================
//
// One home for the magic timeouts / sizes / ports that used to
// be declared inline at use sites. Tuning these without grep
// across the runtime — and making them discoverable in one
// place — is the goal of #328.
//
// Keep this surface narrow. Adding a new constant means it is
// genuinely tunable, not just a local internal limit. Constants
// stay public-let so they're cheap to read in hot paths.

import Foundation

/// Runtime-wide default values. Where a user-facing configuration
/// system needs to override one of these, the Configure action /
/// `aro.toml` reader copies it onto the relevant component at
/// startup; these are the fallbacks.
public enum RuntimeDefaults {
    /// Default deadline for waiting on a single event handler to
    /// finish. Per-publish overrides are still supported on
    /// `EventBus.publishAndWait(timeout:)`.
    public static let eventHandlerTimeout: TimeInterval = 10.0

    /// Default deadline for invoking a Python plugin's subprocess
    /// action. Long-running plugins should declare a higher value
    /// in their `plugin.yaml` (follow-up).
    public static let pythonPluginTimeout: TimeInterval = 30.0

    /// Maximum number of distinct URLs the crawl-style visited
    /// dedup keeps in memory before evicting the oldest. The
    /// BoundedSet's eviction is amortised O(1) so the cost is
    /// purely the memory budget.
    public static let visitedURLStoreMaxSize: Int = 100_000
}
