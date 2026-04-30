// ============================================================
// LazyActionMode.swift
// ARORuntime - Async-by-default Action Execution Flag (Issue #55)
// ============================================================
//
// Phase 7: lazy mode is now the DEFAULT. Set ARO_LAZY_ACTIONS=0 (or
// "off" / "false" / "no") to fall back to the eager path. Phases 1-6
// landed all the supporting machinery (AROFuture, ActionTaskExecutor,
// force points, TaskLocal slot ownership, slow-force diagnostics);
// flipping the default makes the deadlock-free path the one users get
// without opting in.
//
// The eager path is still in tree as the opt-out, so any regression
// reachable only under lazy mode can be quickly mitigated by setting
// the env var. A future cleanup can remove the eager path entirely
// once the lazy path has soaked.

import Foundation

public enum LazyActionMode {

    /// Whether async-by-default action execution is enabled.
    ///
    /// Phase 7 flip: defaults to **true** when ARO_LAZY_ACTIONS is unset.
    /// Recognized opt-out values: "0", "off", "false", "no" (case-insensitive).
    /// Any other value (including "1", "true", "yes") keeps the lazy path on.
    public static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["ARO_LAZY_ACTIONS"] else {
            return true
        }
        switch raw.lowercased() {
        case "0", "off", "false", "no":
            return false
        default:
            return true
        }
    }()
}
