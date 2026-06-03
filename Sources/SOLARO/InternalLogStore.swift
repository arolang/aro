// ============================================================
// InternalLogStore.swift
// SOLARO — single buffer for every internal/external transcript
// ============================================================
//
// Captures both LSP traffic (JSON-RPC frames with `aro lsp`) and
// Ask traffic (prompts + responses to `aro ask`). Surfaced via
// View → Internal Logs… with category checkboxes so the user can
// focus on one channel at a time.
//
// Backward-compat: the previous standalone `LSPLogStore` collapsed
// into this — every call site now records with an explicit
// category. The single-store shape keeps the timeline coherent so
// the user can see "first the LSP went silent, then we fell back
// to Ask" without flipping between windows.

import Foundation

@MainActor
@Observable
final class InternalLogStore {
    struct Entry: Identifiable, Equatable {
        enum Category: String, CaseIterable, Identifiable, Hashable {
            case lsp = "LSP"
            case ask = "Ask"
            var id: String { rawValue }
        }

        enum Direction: String, Equatable, Hashable {
            case outbound, inbound, info, error
        }

        let id = UUID()
        let timestamp: Date
        let category: Category
        let direction: Direction
        let summary: String
        let body: String
    }

    private(set) var entries: [Entry] = []
    /// Cap memory at ~800 entries; oldest evicted. Each LSP frame
    /// is small, so even a chatty session stays well under a MB.
    private let maxEntries = 800

    static let shared = InternalLogStore()

    func record(
        category: Entry.Category,
        direction: Entry.Direction,
        summary: String,
        body: String
    ) {
        entries.append(.init(
            timestamp: Date(),
            category: category,
            direction: direction,
            summary: summary,
            body: body
        ))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}
