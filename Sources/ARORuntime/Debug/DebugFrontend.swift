// ============================================================
// DebugFrontend.swift
// ARO Runtime - Debugger Frontend Protocol
// ============================================================
//
// The protocol every debugger UI implements. Phase 1 (issue #229) ships
// a CLI TUI frontend (`AROCLI.DebugCommand`). Phase 2 adds a DAP server
// that conforms to this protocol. The runtime never talks to a frontend
// directly — only through this surface.

import Foundation

/// What the runtime should do after a pause completes.
public enum StepMode: Sendable, Equatable {
    /// Run until the next statement in the same feature set, skipping over
    /// emits / sub-graph calls.
    case stepOver
    /// Follow the next emit or sub-graph call. Phase 1 treats this as
    /// `stepOver` until inter-feature-set call stacks land in Phase 3.
    case stepIn
    /// Run until control returns to the caller of the current feature set.
    /// Phase 1 treats this as `continue` until call stacks land.
    case stepOut
    /// Resume execution until the next breakpoint or program end.
    case `continue`
}

/// Frontend interface. The runtime calls `didPause` from within a
/// `DebugController` actor; the frontend may freely await other I/O.
public protocol DebugFrontend: AnyObject, Sendable {
    /// Called when execution pauses. The frontend handles user interaction
    /// (or DAP traffic) and returns the next step mode. Mutating breakpoint
    /// state during the pause is fine — call into the controller via the
    /// passed handle.
    func didPause(
        _ pause: PauseInfo,
        controller: DebugController
    ) async -> StepMode

    /// Called once when the debug session is being torn down — either the
    /// program ended cleanly, errored, or the user quit. After this returns
    /// the controller is no longer valid.
    func didEnd(error: Error?) async
}
