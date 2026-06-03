// ============================================================
// GhostState.swift
// SOLARO — shared observable state for the inline ghost popover
// ============================================================
//
// The popover is an NSHostingController hosting a SwiftUI view;
// the view reads from this @Observable so AROHoverTextView can
// push selection / AI updates without rebuilding the host.

import SwiftUI

@MainActor
@Observable
final class GhostState {
    var items: [AROLSPClient.CompletionItem] = []
    /// Currently-highlighted row. `-1` means the AI suggestion at
    /// the top of the popover is selected; `0..<items.count`
    /// means the corresponding LSP item is selected.
    var selectedIndex: Int = 0
    /// Sentinel: the AI row exists as a selectable entry only when
    /// `aro ask` actually returned non-empty text.
    var canSelectAI: Bool {
        guard let suggestion = aiSuggestion else { return false }
        return !suggestion.isEmpty
    }
    static let aiRowIndex: Int = -1
    /// AI fallback suggestion, set after the popover has been
    /// open for ~1s and `solaro.editor.aiFallback` is on.
    var aiSuggestion: String? = nil
    var aiLoading: Bool = false
    /// True once the user has Tab-entered the popover. Before that
    /// the user can still keep typing; after, arrows + Enter take
    /// over.
    var inNavMode: Bool = false

    /// The partial word the user has typed at the caret when the
    /// popover opened. The view filters `items` by this prefix so
    /// the list narrows to what the user is actually typing —
    /// without it, the popover shows the LSP's full alphabetical
    /// dump and `Accept` always sits at the top regardless of
    /// what the user meant.
    var typedPrefix: String = ""

    /// Items filtered by `typedPrefix` (case-insensitive). Prefix
    /// matches first; falls back to substring matches if nothing
    /// starts with the typed letters so the user still sees a list.
    var visibleItems: [AROLSPClient.CompletionItem] {
        let needle = typedPrefix.lowercased()
        guard !needle.isEmpty else { return items }
        let starts = items.filter { $0.label.lowercased().hasPrefix(needle) }
        if !starts.isEmpty { return starts }
        return items.filter { $0.label.lowercased().contains(needle) }
    }

    func reset() {
        items = []
        selectedIndex = 0
        aiSuggestion = nil
        aiLoading = false
        inNavMode = false
        typedPrefix = ""
    }
}
