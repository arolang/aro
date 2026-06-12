// ============================================================
// ActionCatalog.swift
// AROParser — shared catalog of built-in action verb names
// ============================================================
//
// Single source of truth for the lowercase verb names of every
// built-in action. Consulted by:
//
//   - `AROCompiler.LLVMExternalDeclEmitter` to declare the
//     `@_cdecl("aro_action_<verb>")` external function symbols
//     the LLVM IR calls into.
//   - The runtime's `ActionRegistry` indirectly — each Action
//     implementation declares its own `verbs: Set<String>`; this
//     catalog enumerates the union so the codegen list and the
//     dispatch table can't silently diverge (#336).
//
// AROParser is the only module imported by both AROCompiler and
// ARORuntime, so the catalog lives here. The entries are
// lowercase forms that match Action implementations'
// `verbs: Set<String>` after normalisation.

import Foundation

/// Lowercase verb names of every built-in action that the LLVM
/// codegen path emits an `@_cdecl("aro_action_<verb>")` external
/// for. Adding a new built-in action requires appending the verb
/// here so the emitter can declare the symbol, and also
/// registering an Action implementation in the runtime. Tests on
/// the runtime side check that every registered Action's verbs
/// appear here.
public enum ActionCatalog {
    public static let allActionVerbs: [String] = [
        // Request actions
        "extract", "fetch", "retrieve", "parse", "parsehtml", "read",
        "request", "receive",
        // Own actions
        "compute", "validate", "compare", "transform", "create", "update",
        "accept",
        // Response actions
        "return", "throw", "emit", "send", "log", "store", "write", "publish",
        // Server actions
        "start", "listen", "route", "watch", "stop", "keepalive", "broadcast",
        "connect",
        // External call
        "call",
        // Data pipeline (ARO-0018)
        "filter", "reduce", "map", "group",
        // Sort
        "sort", "order", "arrange",
        // System exec (ARO-0033)
        "exec", "shell",
        // Repository
        "delete", "merge", "combine", "join", "concat", "close",
        // String (ARO-0037)
        "split",
        // File operations (ARO-0036)
        "list", "stat", "exists", "make", "touch", "createdirectory", "mkdir",
        "copy", "move", "rename", "append",
        // Configuration
        "configure",
        // Notifications
        "notify", "alert", "signal",
        // SSE / WebSocket streaming
        "stream", "subscribe",
        // Terminal UI
        "render", "clear", "show",
    ]
}
