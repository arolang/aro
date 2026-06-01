// ============================================================
// WorkspaceState.swift
// SOLARO — top-level routing state
// ============================================================
//
// The two states the app can be in: a welcome screen (no project) or
// an open workspace (a project directory loaded). Phase 0 only ever
// observes the `.welcome` state; Phase 1+ populates `.open(...)` with
// a real `Project` model.

import Foundation

/// Coarse routing state for the SOLARO window. One of two cases:
/// nothing open → welcome panel; project open → workspace.
enum WorkspaceState {
    case welcome
    case open(Project)
}

/// Phase 0 stub: a project is just a directory path. Phase 1
/// expands this with discovered source files, the parsed AST, the
/// `.aro.layout.json` sidecar (ADR-004), and per-file pane mode
/// state (ADR-005).
struct Project: Identifiable, Equatable {
    var id: String { rootPath.path }
    let rootPath: URL

    /// Human-readable display name (the directory's last path
    /// component, fall back to the full path).
    var displayName: String {
        rootPath.lastPathComponent.isEmpty ? rootPath.path : rootPath.lastPathComponent
    }
}
