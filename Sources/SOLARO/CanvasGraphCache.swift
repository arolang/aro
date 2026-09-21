// ============================================================
// CanvasGraphCache.swift
// SOLARO — build the canvas graph when it changes, not per frame (#749)
// ============================================================
//
// `canvasGraph` was a computed property read from the canvas's body. Each
// read did a synchronous `LayoutSidecar.load` — open, read and JSON-decode
// the project's `.layout.json` — then `CanvasGraph.build` over every
// statement in the file, `withPositions(from:)` and `StackLayout.place`.
//
// The body re-evaluates on `executionTick`, which is bumped once per live
// event batch. So during a run — the thing the canvas exists to show — a hot
// loop rebuilt the whole graph and re-read the sidecar many times a second.
//
// The graph is a pure function of three inputs, so it is cached on them:
//
//   * the file,
//   * the parsed program, which changes only when something reparses,
//   * the sidecar, whose node positions the user drags around.
//
// The program is tracked by a generation counter the controller bumps on any
// mutation of `programs`; the sidecar by its size and modification date,
// which costs one `stat` instead of a read and a decode. A drag that saves
// positions also invalidates explicitly, so a write and a read inside the
// same filesystem timestamp tick cannot serve a stale layout.

import Foundation

/// Cached canvas graphs, keyed by the inputs they were built from.
///
/// Held `@ObservationIgnored` on the controller: the cache is derived state,
/// so a view reading it must not register a dependency on it, and filling it
/// during a body pass must not invalidate that pass.
struct CanvasGraphCache {

    private struct Stamp: Equatable {
        let programGeneration: Int
        let sidecarSize: Int
        let sidecarModified: Date?
    }

    private struct Entry {
        let stamp: Stamp
        let graph: CanvasGraph
    }

    private var entries: [URL: Entry] = [:]

    /// Resolved `.layout.json` path per source file.
    ///
    /// `ProjectLayoutStore.storeURL` walks up to eight directories looking
    /// for a project marker, listing each one along the way. That is fine
    /// once and far too much per body pass — it is the same class of cost
    /// this cache exists to remove. A file's project root does not move
    /// while the window is open.
    private var storeURLs: [URL: URL] = [:]

    /// Bumped on every mutation of the controller's `programs`.
    private(set) var programGeneration: Int = 0

    /// Invalidate everything built from a program.
    mutating func noteProgramsChanged() {
        programGeneration &+= 1
    }

    /// Invalidate everything built from a sidecar — a node drag, a pane-mode
    /// change, a breakpoint move.
    mutating func noteSidecarChanged() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Forget everything, resolved project roots included.
    ///
    /// For a project being closed or reloaded, where the root itself may
    /// have changed underneath us.
    mutating func reset() {
        entries.removeAll(keepingCapacity: false)
        storeURLs.removeAll(keepingCapacity: false)
    }

    /// The graph for `url`, building it with `build` only when an input has
    /// changed since the last call.
    mutating func graph(for url: URL,
                        build: () -> CanvasGraph) -> CanvasGraph {
        let stamp = currentStamp(for: url)
        if let entry = entries[url], entry.stamp == stamp {
            return entry.graph
        }
        let graph = build()
        entries[url] = Entry(stamp: stamp, graph: graph)
        return graph
    }

    private mutating func currentStamp(for url: URL) -> Stamp {
        // One `stat` of the consolidated `.layout.json`. A missing file is a
        // valid state — most projects never save a layout — and stamps as
        // size 0 with no date, which is stable, so it caches like any other.
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: storeURL(for: url).path)
        return Stamp(
            programGeneration: programGeneration,
            sidecarSize: (attributes?[.size] as? Int) ?? 0,
            sidecarModified: attributes?[.modificationDate] as? Date
        )
    }

    private mutating func storeURL(for url: URL) -> URL {
        if let known = storeURLs[url] { return known }
        let resolved = ProjectLayoutStore.storeURL(for: url)
        storeURLs[url] = resolved
        return resolved
    }
}
