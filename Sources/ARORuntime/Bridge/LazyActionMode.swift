// ============================================================
// LazyActionMode.swift
// ARORuntime - Async-by-default Action Execution Flag (Issue #55)
// ============================================================
//
// Reads ARO_LAZY_ACTIONS once at runtime startup. Off by default in
// Phase 1 — every call site that branches on this flag still defaults
// to the eager (semaphore-blocking) path. Phase 2 onwards wires the
// flag through ActionRunner / LLVMCodeGenerator. Phase 7 flips the
// default and removes the flag entirely.

import Foundation

public enum LazyActionMode {

    /// Whether async-by-default action execution is enabled.
    ///
    /// Controlled by the `ARO_LAZY_ACTIONS` environment variable.
    /// Recognized values: "1", "true", "yes" (case-insensitive). Anything
    /// else — including the variable being unset — keeps the eager path.
    public static let isEnabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["ARO_LAZY_ACTIONS"] else {
            return false
        }
        switch raw.lowercased() {
        case "1", "true", "yes":
            return true
        default:
            return false
        }
    }()
}
