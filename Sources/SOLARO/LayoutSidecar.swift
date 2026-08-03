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

    /// Phase 15: 1-indexed source lines where the editor's gutter
    /// shows a breakpoint marker. Persisted next to the file so a
    /// debugging session resumes with the same breakpoints set.
    ///
    /// This stays the source of truth for "is there a breakpoint on
    /// this line." Richer per-line settings (condition / logpoint)
    /// live in `breakpointConfigs`, keyed by the same line number; a
    /// line present here with no config entry is a plain regular
    /// breakpoint. Old sidecars that predate `breakpointConfigs`
    /// decode cleanly — every breakpoint reads back as plain regular.
    var breakpoints: Set<Int> = []

    /// Issue #259 — per-line breakpoint refinements, keyed by the
    /// 1-indexed line number as a string (JSON object keys must be
    /// strings). Only lines that differ from a plain regular
    /// breakpoint appear here; a missing entry means "regular, no
    /// condition." Defaults to empty so pre-#259 sidecars migrate
    /// forward without losing data.
    var breakpointConfigs: [String: BreakpointConfig] = [:]

    /// Refinement carried by a single breakpoint line (#259).
    /// `regular` breakpoints pause (unconditionally, or only when
    /// `condition` is truthy); `logpoint` breakpoints never pause —
    /// they log `logMessage` (with `{var}` interpolation) and
    /// continue.
    struct BreakpointConfig: Codable, Equatable {
        enum Kind: String, Codable { case regular, logpoint }

        /// Regular (pauses) vs. logpoint (traces without pausing).
        var kind: Kind = .regular
        /// Optional ARO expression. When set on a `regular`
        /// breakpoint the debugger pauses only when it evaluates
        /// truthy at that line.
        var condition: String? = nil
        /// Logpoint message with `{variableName}` interpolation.
        /// Only meaningful when `kind == .logpoint`.
        var logMessage: String? = nil

        init(kind: Kind = .regular,
             condition: String? = nil,
             logMessage: String? = nil) {
            self.kind = kind
            self.condition = condition
            self.logMessage = logMessage
        }

        /// True when this config carries no refinement — i.e. it is
        /// equivalent to a plain regular breakpoint. Callers prune
        /// these so the sidecar only stores meaningful settings.
        var isPlainRegular: Bool {
            kind == .regular
                && (condition?.isEmpty ?? true)
                && (logMessage?.isEmpty ?? true)
        }
    }

    /// The effective config for `line`. Returns the stored refinement
    /// when present, else a default plain regular breakpoint. Safe to
    /// call for any line — it does not assert the line is in
    /// `breakpoints`.
    func breakpointConfig(forLine line: Int) -> BreakpointConfig {
        breakpointConfigs[String(line)] ?? BreakpointConfig()
    }

    /// Set (or clear) the refinement for `line`. A plain-regular
    /// config is stored as *absence* so the sidecar stays minimal and
    /// round-trips identically to a pre-#259 file. Does not touch
    /// `breakpoints`; callers keep the marker set in sync.
    mutating func setBreakpointConfig(_ config: BreakpointConfig, forLine line: Int) {
        if config.isPlainRegular {
            breakpointConfigs.removeValue(forKey: String(line))
        } else {
            breakpointConfigs[String(line)] = config
        }
    }

    // Custom Codable so a sidecar written by an OLDER SOLARO — which
    // has no `breakpointConfigs` key (and, for truly old files, no
    // `breakpoints` key either) — still decodes cleanly instead of
    // throwing `keyNotFound`. Swift's *synthesized* decoder requires
    // every non-optional key to be present even when the property has a
    // default value, so we decode each field with `decodeIfPresent` and
    // fall back to the default. This is the crux of the #259 forward
    // migration: old files load, missing new fields default to "plain
    // regular breakpoint," and no existing data is dropped.
    enum CodingKeys: String, CodingKey {
        case paneMode, nodes, view, breakpoints, breakpointConfigs
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paneMode = try c.decodeIfPresent(PaneMode.self, forKey: .paneMode) ?? .text
        nodes = try c.decodeIfPresent([String: NodePosition].self, forKey: .nodes) ?? [:]
        view = try c.decodeIfPresent(ViewState.self, forKey: .view) ?? .init()
        breakpoints = try c.decodeIfPresent(Set<Int>.self, forKey: .breakpoints) ?? []
        breakpointConfigs = try c.decodeIfPresent(
            [String: BreakpointConfig].self, forKey: .breakpointConfigs) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paneMode, forKey: .paneMode)
        try c.encode(nodes, forKey: .nodes)
        try c.encode(view, forKey: .view)
        try c.encode(breakpoints, forKey: .breakpoints)
        try c.encode(breakpointConfigs, forKey: .breakpointConfigs)
    }

    struct NodePosition: Codable, Equatable {
        var x: Double
        var y: Double
    }

    struct ViewState: Codable, Equatable {
        var zoom: Double = 1.0
        var scrollX: Double = 0
        var scrollY: Double = 0
    }

    /// Path to the per-file sidecar a previous SOLARO version
    /// wrote (`users.aro.layout.json`). Still resolved so the
    /// migration pass can find and consume these files; the live
    /// path is the consolidated `<root>/.layout.json` via
    /// `ProjectLayoutStore`.
    static func legacySidecarURL(for source: URL) -> URL {
        let parent = source.deletingLastPathComponent()
        let name = source.lastPathComponent + ".layout.json"
        return parent.appendingPathComponent(name)
    }

    /// Read the entry for `source` out of the project's
    /// consolidated `.layout.json`. Returns a default-initialised
    /// `LayoutSidecar` when no entry exists (and no legacy
    /// `*.aro.layout.json` was migrated in) — the UI never errors
    /// on a missing sidecar.
    static func load(for source: URL) -> LayoutSidecar {
        var store = ProjectLayoutStore.load(for: source)
        // Migration: if `store` was empty but a legacy file exists
        // next to `source`, fold it in so the user keeps their
        // saved positions / pane mode / breakpoints.
        let key = store.key(for: source)
        if store.files[key] == nil,
           let legacy = readLegacy(for: source) {
            store.files[key] = legacy
            try? store.save()
            try? FileManager.default.removeItem(at: legacySidecarURL(for: source))
        }
        return store.files[key] ?? LayoutSidecar()
    }

    /// Write atomically through the project's consolidated file.
    /// Errors propagate so the caller can surface disk-full /
    /// permission issues in the inspector.
    func save(for source: URL) throws {
        var store = ProjectLayoutStore.load(for: source)
        store.files[store.key(for: source)] = self
        try store.save()
        // Best-effort cleanup of a stale legacy file. Failures are
        // ignored — the consolidated store is authoritative either
        // way.
        let legacy = LayoutSidecar.legacySidecarURL(for: source)
        try? FileManager.default.removeItem(at: legacy)
    }

    /// Parse a per-file legacy sidecar at `<source>.layout.json`.
    /// Returns nil when the file is missing or malformed so the
    /// caller can fall through to a default-initialised value.
    private static func readLegacy(for source: URL) -> LayoutSidecar? {
        let url = legacySidecarURL(for: source)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder()
                  .decode(LayoutSidecar.self, from: data)
        else { return nil }
        return decoded
    }
}

/// Project-wide layout store. One file per project rather than one
/// per source file — keeps the project directory tidy and makes it
/// easy to copy a whole project's pane state between machines. The
/// on-disk shape:
///
/// ```json
/// {
///   "version": 2,
///   "files": {
///     "crawler.aro": { paneMode, nodes, view, breakpoints, breakpointConfigs },
///     "main.aro":    { ... }
///   }
/// }
/// ```
///
/// File-path keys are project-relative so the file is portable.
/// Files outside the root are stored under their absolute path as
/// a fallback.
///
/// Schema history:
///   * v1 — paneMode, nodes, view, breakpoints (`Set<Int>`).
///   * v2 — adds per-line `breakpointConfigs` (conditional
///          breakpoints + logpoints, issue #259). All new fields
///          are additive with defaults, so v1 files decode cleanly
///          and are re-stamped to v2 on the next save.
struct ProjectLayoutStore: Codable, Equatable {
    /// Current on-disk schema version. Bumped 1 → 2 for #259 so a
    /// file written by this build is recognisably newer than a
    /// pre-#259 one.
    static let currentSchemaVersion = 2

    var version: Int = currentSchemaVersion
    var files: [String: LayoutSidecar] = [:]

    /// On-disk filename at the project root.
    static let storeFilename: String = ".layout.json"

    /// Walk up from `source` until we find the project root —
    /// the closest ancestor that contains an `aro.toml`,
    /// `openapi.yaml`, an existing `.layout.json`, or any `.aro`
    /// file. Fall back to the source's immediate parent so flat
    /// projects (a single `.aro` in a folder) still get a single
    /// store next to the file.
    static func projectRoot(for source: URL) -> URL {
        let fm = FileManager.default
        var dir = source.deletingLastPathComponent()
        // `aro.yaml` is the canonical project manifest; `aro.toml`
        // is kept for backwards-compatibility with older projects.
        let markers = ["aro.yaml", "aro.toml", "openapi.yaml", storeFilename]
        for _ in 0..<8 {
            for marker in markers {
                let candidate = dir.appendingPathComponent(marker)
                if fm.fileExists(atPath: candidate.path) {
                    return dir
                }
            }
            // Falls into the "has any .aro file" check so a project
            // without openapi / aro.toml still resolves cleanly.
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path),
               entries.contains(where: { $0.hasSuffix(".aro") })
            {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }   // top of the tree
            dir = parent
        }
        return source.deletingLastPathComponent()
    }

    /// Absolute path to the consolidated store for `source`'s project.
    static func storeURL(for source: URL) -> URL {
        projectRoot(for: source).appendingPathComponent(storeFilename)
    }

    /// Load the consolidated store. Returns a fresh, empty store
    /// when the file is missing or malformed — same forgiveness
    /// behavior as the legacy per-file path.
    static func load(for source: URL) -> ProjectLayoutStore {
        let url = storeURL(for: source)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProjectLayoutStore.self, from: data)
        else { return ProjectLayoutStore(root: projectRoot(for: source)) }
        var out = decoded
        out.rootPath = projectRoot(for: source)
        // Re-stamp to the current schema version so a v1 file that is
        // loaded and later saved records that it now carries v2 fields.
        // Decoding already folded in the new `breakpointConfigs` field
        // with its default (empty), so no data is lost either way.
        out.version = Self.currentSchemaVersion
        return out
    }

    /// Project root used to compute relative keys. Not encoded;
    /// resolved fresh on every load.
    var rootPath: URL? = nil

    init(version: Int = currentSchemaVersion, files: [String: LayoutSidecar] = [:]) {
        self.version = version
        self.files = files
    }

    init(root: URL) {
        self.version = Self.currentSchemaVersion
        self.files = [:]
        self.rootPath = root
    }

    enum CodingKeys: String, CodingKey {
        case version, files
    }

    /// Compute the dictionary key for `source`. Project-relative
    /// when `source` lives under the root; absolute path otherwise
    /// so out-of-tree files still get persisted.
    func key(for source: URL) -> String {
        let abs = source.standardizedFileURL.path
        guard let root = rootPath?.standardizedFileURL.path else {
            return abs
        }
        if abs.hasPrefix(root + "/") {
            return String(abs.dropFirst(root.count + 1))
        }
        return abs
    }

    func save() throws {
        guard let root = rootPath else { return }
        let url = root.appendingPathComponent(Self.storeFilename)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }

    /// One-shot migration pass on project open: walk `root` for
    /// any leftover `*.layout.json` files (the per-file sidecars
    /// older SOLARO versions wrote), fold each one into the
    /// consolidated store, and delete the per-file originals.
    /// Cheap to call repeatedly — after the first pass there's
    /// nothing left to find. Errors during read/delete are
    /// swallowed so a permission glitch on a single file doesn't
    /// abort the whole migration.
    static func migrateLegacySidecars(at root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        let legacy = entries.filter {
            $0.lastPathComponent.hasSuffix(".layout.json")
                && $0.lastPathComponent != storeFilename
        }
        guard !legacy.isEmpty else { return }
        var store = load(for: root.appendingPathComponent("dummy.aro"))
        // `load(for:)` resolves the root via marker files; force
        // the explicit value so it lands in this project even on
        // fresh disks where no `.layout.json` exists yet.
        store.rootPath = root
        for legacyURL in legacy {
            // `users.aro.layout.json` → `users.aro`. Strip
            // `.layout.json` to recover the source filename.
            let name = String(legacyURL.lastPathComponent
                .dropLast(".layout.json".count))
            let sourceURL = root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: legacyURL),
                  let decoded = try? JSONDecoder()
                      .decode(LayoutSidecar.self, from: data)
            else {
                // Malformed — drop it rather than carry forever.
                try? fm.removeItem(at: legacyURL)
                continue
            }
            let key = store.key(for: sourceURL)
            if store.files[key] == nil {
                store.files[key] = decoded
            }
            try? fm.removeItem(at: legacyURL)
        }
        try? store.save()
    }
}

/// The four center-pane projections. Mirrors the wireframe set
/// (notes 8467 and 8519 on issue #228).
enum PaneMode: String, Codable, CaseIterable, Equatable, Identifiable {
    // Map leads the picker so the project-overview view is the
    // first icon — relative order of the others is unchanged.
    case map
    case canvas
    case text
    case split

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
