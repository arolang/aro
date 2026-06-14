// ============================================================
// WorkspaceSubstates.swift
// SOLARO — domain state bundles extracted from WorkspaceController
// ============================================================
//
// First slice of #299. `WorkspaceController` accumulated 89+
// properties spanning editor caret, canvas selection, repository
// payloads, global search, find-in-file, debugger snapshots,
// LSP state, UI flags, …. Views couldn't subscribe to "just the
// canvas selection" without observing the whole controller.
//
// The fields below moved into focused value types
// (`EditorFindState`, `CanvasSelectionState`, `GlobalSearchState`,
// `RepositoryState`). The controller still owns one of each and
// forwards the old flat property names so existing call sites
// don't have to change. Adding more bundles is a one-struct-at-
// a-time follow-up: pick a property cluster, lift it into a
// struct here, and add the forwarders on the controller.
//
// Value types (not @Observable classes) so the @Observable macro
// on the controller tracks each bundle as a single stored
// property — mutations to inner fields propagate through Swift
// value semantics without per-field withMutation boilerplate.

import Foundation

/// In-editor find-bar state (⌘F flow).
struct EditorFindState: Equatable {
    var active: Bool = false
    var query: String = ""
    /// Match selection the editor should apply on its next
    /// updateNSView. Cleared after the editor consumes it (the
    /// editor watches `selectionTick` for re-apply triggers).
    var selection: NSRange?
    /// Bumped each time a new selection is pushed; the editor
    /// stores the last tick it consumed and only re-applies when
    /// the tick advances.
    var selectionTick: UInt64 = 0
}

/// Canvas selection + drag state (#266 multi-select + node drags).
struct CanvasSelectionState {
    /// Multi-node selection. Click sets one ID, ⌘-click toggles,
    /// rubber-band on blank space replaces the set.
    var selectedIDs: Set<String> = []
    /// Single-node mirror — the most recently added member of
    /// `selectedIDs`. Inspector binds to this so it always shows
    /// one node at a time even when several are highlighted.
    var selectedNode: CanvasNode? = nil
    /// Raw source text spanned by `selectedNode`; captured at
    /// click time because the Inspector doesn't otherwise have
    /// access to it.
    var selectedNodeSource: String? = nil
    /// Selected repository entity (the blue capsules on the
    /// canvas). Mutually exclusive with `selectedNode` — clicking
    /// either side clears the other so the inspector only ever
    /// renders one form at a time.
    var selectedRepository: RepositoryNode? = nil
    /// User-dragged node and repository positions, keyed by node
    /// / repo ID. Lives here (not as @State on CanvasView) so the
    /// UndoManager handler can restore an old position by writing
    /// back through the controller.
    var liveNodes: [String: CGPoint] = [:]
}

/// Toolbar global-search results panel state.
struct GlobalSearchPanelState {
    var hits: [GlobalSearchHit] = []
    /// 0-indexed position of the keyboard-/hover-highlighted row.
    var selectedIndex: Int = 0
    /// True when the results panel should be visible — flips to
    /// false on Esc, focus loss, or after a hit is opened.
    var panelVisible: Bool = false
}

/// Repository payloads observed during a run.
struct RepositoryState {
    /// Most recent value the runtime saw flowing into each
    /// repository, keyed by repository object name.
    var values: [String: ConsoleProcess.SymbolValue] = [:]
    /// Rolling history (newest first) of the last N payloads per
    /// repository. Capped by the producer so a hot loop doesn't
    /// grow memory.
    var history: [String: [ConsoleProcess.SymbolValue]] = [:]
    /// Current rows held by each repository, projected to flat
    /// dictionaries for the RepoCard inline table (#284 step 3).
    var records: [String: [[String: String]]] = [:]
}
