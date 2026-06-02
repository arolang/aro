// ============================================================
// LayoutSidecar.swift
// SOLARO — `.aro.layout.json` reader / writer (ADR-004 / ADR-005)
// ============================================================
//
// Per-file pane mode (Canvas / Text / Split / Map) plus the canvas
// node positions live next to each `.aro` file as
// `<filename>.aro.layout.json`. Gitignored by default; projects
// that want shared diagrams opt in via a workspace flag in
// `aro.toml`.

import Foundation

/// Persistent per-file layout state. Tiny on disk — a few hundred
/// bytes per file. Phase 1 only persists `paneMode`; canvas node
/// positions land in Phase 2 (`nodes`).
struct LayoutSidecar: Codable, Equatable {
    /// Last-used pane mode for this file. Default `.text` so new
    /// files open in the editor (the only universally-implemented
    /// pane mode through Phase 7). Phases 8/10 enable Canvas / Split
    /// / Map; users opt in by switching modes — the choice persists
    /// here for next time.
    var paneMode: PaneMode = .text

    /// Reserved for Phase 2 — node positions by AST id.
    var nodes: [String: NodePosition] = [:]

    /// Reserved for Phase 2 — canvas zoom + scroll offset.
    var view: ViewState = .init()

    struct NodePosition: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct ViewState: Codable, Equatable {
        var zoom: Double = 1.0
        var scrollX: Double = 0
        var scrollY: Double = 0
    }

    /// Path to the sidecar next to an `.aro` source file.
    /// `users.aro` → `users.aro.layout.json`.
    static func sidecarURL(for source: URL) -> URL {
        let parent = source.deletingLastPathComponent()
        let name = source.lastPathComponent + ".layout.json"
        return parent.appendingPathComponent(name)
    }

    /// Read the sidecar next to `source`. Returns a default-
    /// initialized `LayoutSidecar` when the file is missing or
    /// unreadable — the UI never errors on a missing sidecar.
    static func load(for source: URL) -> LayoutSidecar {
        let url = sidecarURL(for: source)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(LayoutSidecar.self, from: data)
        else { return LayoutSidecar() }
        return decoded
    }

    /// Write atomically. Errors propagate so the caller can surface
    /// disk-full / permission issues in the inspector.
    func save(for source: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        let url = LayoutSidecar.sidecarURL(for: source)
        try data.write(to: url, options: [.atomic])
    }
}

/// The four center-pane projections. Mirrors the wireframe set
/// (notes 8467 and 8519 on issue #228).
enum PaneMode: String, Codable, CaseIterable, Equatable, Identifiable {
    case canvas
    case text
    case split
    case map

    var id: String { rawValue }

    var label: String {
        switch self {
        case .canvas: return "Canvas"
        case .text:   return "Text"
        case .split:  return "Split"
        case .map:    return "Map"
        }
    }

    /// SF Symbol used in the workspace toolbar's segmented pane-mode
    /// picker. Picked to read as: graph, text, split, network.
    var symbol: String {
        switch self {
        case .canvas: return "circle.hexagongrid"
        case .text:   return "text.alignleft"
        case .split:  return "rectangle.split.2x1"
        case .map:    return "point.3.connected.trianglepath.dotted"
        }
    }
}
