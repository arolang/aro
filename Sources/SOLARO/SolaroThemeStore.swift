// ============================================================
// SolaroThemeStore.swift
// SOLARO — finding, loading and installing a theme (GitLab #269)
// ============================================================
//
// `SolaroThemeFile` is the format. This is everything that touches
// the world: where theme files live, which one is selected, what
// happens when the selected one is missing or broken, and how a swap
// reaches views that have already drawn.
//
// Discovery follows the pattern the rest of the app's user state
// already uses — `RecentProjects`, `RunParameterDefaults`, the crash
// log store and the book cache all live under
// `~/Library/Application Support/SOLARO/`, so themes are
// `~/Library/Application Support/SOLARO/Themes/*.json` and nothing
// new had to be invented. Which theme is *selected* is a preference,
// so it is a `solaro.*` key in `UserDefaults` like every other one,
// enumerable via `defaults export com.arolang.SOLARO` (#776).
//
// The curated presets are compiled in rather than shipped as a
// resource directory. The SOLARO target has no resource bundle at all
// — nothing in `Sources/` uses `Bundle.module` — so a
// `Resources/Themes/` would have meant a new SwiftPM resource rule
// *and* teaching `Scripts/package-solaro-dmg.sh` to carry the
// generated bundle into the `.app`. Five palettes of 26 hex strings
// are not worth that, and as compiled-in JSON they go through exactly
// the same parser a user's file does, so a typo in a preset fails the
// same test a typo in a user file would.
//
// Precedence: a file in the user's Themes folder wins over a preset
// of the same name, so dropping `nord.json` in the folder customises
// Nord rather than fighting it.

import Foundation
import SwiftUI
import AppKit
import Observation

// MARK: - The live palette

/// The palette `SolaroColor` reads, and the one place a theme is
/// installed.
///
/// Two jobs beyond holding tokens:
///
/// *Memoisation.* A token's `Color` is built once and kept, because
/// `SolaroColor.textSecondary` is compared against itself all over the
/// app (`SyntaxHighlighter` decides whether a verb had a role by it)
/// and SwiftUI colour equality compares the backing providers. Handing
/// out a fresh `NSColor` per access would make a colour unequal to
/// itself.
///
/// *Change notification.* `color(_:)` reads `generation`, an
/// `@Observable` property, so every SwiftUI body that touches a SOLARO
/// colour registers a dependency on it. Bumping it on install
/// re-renders exactly those views and nothing else — no window
/// identity change, so no open tab, scroll position or selection is
/// lost in a theme swap.
///
/// Mutation is main-actor only (`install` says so); reads happen
/// wherever a view body or a highlighter runs, which is why the cache
/// sits behind a lock. `ObservationRegistrar` is itself thread-safe.
@Observable
final class SolaroPalette: @unchecked Sendable {

    /// What `SolaroColor` reads. Tests build their own.
    static let shared = SolaroPalette()

    /// Bumped on every install. Read by `color(_:)` purely so that
    /// SwiftUI observes it — the value itself means nothing outside
    /// the `NSColor` names below.
    private(set) var generation: Int = 0

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var tokens: SolaroThemeTokens = .builtIn
    @ObservationIgnored private var cache: [SolaroColorToken: Color] = [:]

    init(tokens: SolaroThemeTokens = .builtIn) {
        self.tokens = tokens
    }

    /// Replace the palette. A no-op when nothing changed, so a
    /// filesystem event that rewrote a file without changing a colour
    /// does not repaint the app.
    @MainActor
    func install(_ newTokens: SolaroThemeTokens) {
        let changed: Bool = lock.withLock {
            guard newTokens != tokens else { return false }
            tokens = newTokens
            cache.removeAll()
            return true
        }
        guard changed else { return }
        generation += 1
    }

    /// The current palette, for callers that want the data rather than
    /// a `Color` — the Settings pane's override count, and tests.
    var current: SolaroThemeTokens {
        lock.withLock { tokens }
    }

    func color(_ token: SolaroColorToken) -> Color {
        // Register the SwiftUI dependency before the lock: the read
        // has to happen on whatever body is evaluating, and holding a
        // lock across the registrar buys nothing.
        let gen = generation
        return lock.withLock {
            if let hit = cache[token] { return hit }
            let pair = tokens.color(token)
            // Named rather than anonymous. `Color` equality ends up at
            // `NSColor.isEqual:`, and the app relies on two *different*
            // tokens comparing unequal even when they happen to carry
            // the same value (`wireVia` and `wireFrom` do, by default).
            // The generation is in the name so a colour from before a
            // theme swap is never equal to the one that replaced it.
            let ns = NSColor(name: "solaro.\(token.rawValue).\(gen)") { appearance in
                // `bestMatch` answers nil for appearances outside the
                // two we know (increased contrast, for one); the light
                // variant is the safer default there.
                let match = appearance.bestMatch(from: [.aqua, .darkAqua])
                return pair.resolved(dark: match == .darkAqua).nsColor
            }
            let color = Color(nsColor: ns)
            cache[token] = color
            return color
        }
    }
}

// MARK: - Curated presets

/// The themes SOLARO ships. Stored as the JSON a user would write, so
/// they exercise the same parser and can be copied into the Themes
/// folder as a starting point.
enum SolaroThemeCatalog {

    struct Preset: Identifiable, Sendable {
        let id: String
        let json: String
    }

    static let presets: [Preset] = [
        Preset(id: "solarized-light", json: solarizedLight),
        Preset(id: "solarized-dark", json: solarizedDark),
        Preset(id: "dracula", json: dracula),
        Preset(id: "nord", json: nord),
        Preset(id: "github-light", json: githubLight),
    ]

    static func preset(id: String) -> Preset? {
        presets.first { $0.id == id }
    }

    // Ethan Schoonover's Solarized, light and dark. One accent set,
    // two surface sets — which is why both halves are here rather
    // than one file with light/dark pairs: a Solarized user picks a
    // side.
    private static let solarizedLight = """
    {
      "name": "Solarized Light",
      "appearance": "light",
      "colors": {
        "backdrop": "#EEE8D5",
        "surface": "#FDF6E3",
        "surfaceRaised": "#FDF6E3",
        "divider": "#93A1A14D",
        "selection": "#268BD233",
        "textPrimary": "#586E75",
        "textSecondary": "#657B83",
        "textTertiary": "#93A1A1",
        "accent": "#268BD2",
        "stateOK": "#859900",
        "stateWarn": "#B58900",
        "stateError": "#DC322F",
        "roleRequest": "#268BD2",
        "roleOwn": "#6C71C4",
        "roleResponse": "#859900",
        "roleExport": "#CB4B16",
        "wireNeutral": "#93A1A1",
        "wireFrom": "#268BD2",
        "wireTo": "#B58900",
        "wireWith": "#6C71C4",
        "wireInto": "#859900",
        "wireAgainst": "#DC322F",
        "wireVia": "#2AA198",
        "syntaxString": "#2AA198",
        "syntaxNumber": "#D33682",
        "syntaxLiteral": "#CB4B16"
      }
    }
    """

    private static let solarizedDark = """
    {
      "name": "Solarized Dark",
      "appearance": "dark",
      "colors": {
        "backdrop": "#002B36",
        "surface": "#073642",
        "surfaceRaised": "#0B4552",
        "divider": "#586E7566",
        "selection": "#268BD240",
        "textPrimary": "#EEE8D5",
        "textSecondary": "#93A1A1",
        "textTertiary": "#657B83",
        "accent": "#268BD2",
        "stateOK": "#859900",
        "stateWarn": "#B58900",
        "stateError": "#DC322F",
        "roleRequest": "#268BD2",
        "roleOwn": "#6C71C4",
        "roleResponse": "#859900",
        "roleExport": "#CB4B16",
        "wireNeutral": "#657B83",
        "wireFrom": "#268BD2",
        "wireTo": "#B58900",
        "wireWith": "#6C71C4",
        "wireInto": "#859900",
        "wireAgainst": "#DC322F",
        "wireVia": "#2AA198",
        "syntaxString": "#2AA198",
        "syntaxNumber": "#D33682",
        "syntaxLiteral": "#CB4B16"
      }
    }
    """

    private static let dracula = """
    {
      "name": "Dracula",
      "appearance": "dark",
      "colors": {
        "backdrop": "#282A36",
        "surface": "#21222C",
        "surfaceRaised": "#343746",
        "divider": "#FFFFFF1A",
        "selection": "#44475A",
        "textPrimary": "#F8F8F2",
        "textSecondary": "#C7CBD8",
        "textTertiary": "#6272A4",
        "accent": "#BD93F9",
        "stateOK": "#50FA7B",
        "stateWarn": "#F1FA8C",
        "stateError": "#FF5555",
        "roleRequest": "#8BE9FD",
        "roleOwn": "#BD93F9",
        "roleResponse": "#50FA7B",
        "roleExport": "#FFB86C",
        "wireNeutral": "#6272A4",
        "wireFrom": "#8BE9FD",
        "wireTo": "#FFB86C",
        "wireWith": "#BD93F9",
        "wireInto": "#50FA7B",
        "wireAgainst": "#FF5555",
        "wireVia": "#FF79C6",
        "syntaxString": "#F1FA8C",
        "syntaxNumber": "#BD93F9",
        "syntaxLiteral": "#FF79C6"
      }
    }
    """

    private static let nord = """
    {
      "name": "Nord",
      "appearance": "dark",
      "colors": {
        "backdrop": "#2E3440",
        "surface": "#3B4252",
        "surfaceRaised": "#434C5E",
        "divider": "#FFFFFF1A",
        "selection": "#434C5E",
        "textPrimary": "#ECEFF4",
        "textSecondary": "#D8DEE9",
        "textTertiary": "#616E88",
        "accent": "#88C0D0",
        "stateOK": "#A3BE8C",
        "stateWarn": "#EBCB8B",
        "stateError": "#BF616A",
        "roleRequest": "#81A1C1",
        "roleOwn": "#B48EAD",
        "roleResponse": "#A3BE8C",
        "roleExport": "#D08770",
        "wireNeutral": "#4C566A",
        "wireFrom": "#81A1C1",
        "wireTo": "#D08770",
        "wireWith": "#B48EAD",
        "wireInto": "#A3BE8C",
        "wireAgainst": "#BF616A",
        "wireVia": "#8FBCBB",
        "syntaxString": "#A3BE8C",
        "syntaxNumber": "#B48EAD",
        "syntaxLiteral": "#81A1C1"
      }
    }
    """

    private static let githubLight = """
    {
      "name": "GitHub Light",
      "appearance": "light",
      "colors": {
        "backdrop": "#F6F8FA",
        "surface": "#FFFFFF",
        "surfaceRaised": "#FFFFFF",
        "divider": "#D0D7DE",
        "selection": "#0969DA26",
        "textPrimary": "#1F2328",
        "textSecondary": "#656D76",
        "textTertiary": "#6E7781",
        "accent": "#0969DA",
        "stateOK": "#1A7F37",
        "stateWarn": "#9A6700",
        "stateError": "#CF222E",
        "roleRequest": "#0969DA",
        "roleOwn": "#8250DF",
        "roleResponse": "#1A7F37",
        "roleExport": "#BC4C00",
        "wireNeutral": "#8C959F",
        "wireFrom": "#0969DA",
        "wireTo": "#BC4C00",
        "wireWith": "#8250DF",
        "wireInto": "#1A7F37",
        "wireAgainst": "#CF222E",
        "wireVia": "#1B7C83",
        "syntaxString": "#0A3069",
        "syntaxNumber": "#0550AE",
        "syntaxLiteral": "#0550AE"
      }
    }
    """
}

// MARK: - Store

/// Where a selectable theme came from.
enum SolaroThemeOrigin: Equatable, Sendable {
    /// SOLARO's own palette — no file, nothing to go wrong.
    case builtIn
    /// One of the compiled-in curated presets.
    case preset
    /// A file in the user's Themes folder.
    case userFile(URL)
}

/// One row of the theme picker.
struct SolaroThemeEntry: Identifiable, Equatable, Sendable {
    /// Persisted selection token. For a file this is its basename
    /// without the extension, which is also how a user file shadows a
    /// preset of the same name.
    let id: String
    let name: String
    let origin: SolaroThemeOrigin
}

/// Discovery, selection and installation.
///
/// `@Observable` so Settings redraws as the folder changes, and
/// main-actor because it drives the UI and installs into the palette.
/// The three collaborators — directory, defaults, palette — are
/// injected so tests can exercise the whole path (a good file, a
/// partial file, a broken file, a missing file) against a temporary
/// directory without touching the user's own themes or preferences.
@MainActor
@Observable
final class SolaroThemeStore {

    static let shared = SolaroThemeStore(watching: true)

    /// The selection that means "SOLARO's own palette". Not a
    /// filename, so a user file can never collide with it.
    static let builtInID = "built-in"

    /// Every theme that can be selected, built-in first, then presets,
    /// then the user's own.
    private(set) var entries: [SolaroThemeEntry] = []

    /// The selected theme's id. Persisted.
    private(set) var selectionID: String

    /// Problems with the theme that is currently selected, in the
    /// user's terms. Rendered under the picker in Settings and, for
    /// the ones that happen at launch with no Settings window open,
    /// pushed to `SolaroDiagnostics`.
    private(set) var issues: [SolaroThemeIssue] = []

    /// How many of the palette's tokens the selected theme states.
    /// The rest are SOLARO's — which is the thing a partial theme's
    /// author most wants to know.
    private(set) var statedTokenCount: Int = 0

    /// Appearance the selected theme asks for, if it asks.
    private(set) var pinnedAppearance: SolaroTheme?

    private let directory: URL
    private let defaults: UserDefaults
    private let palette: SolaroPalette
    @ObservationIgnored private var watcher: ExternalFileWatcher?

    init(directory: URL = SolaroThemeStore.defaultDirectory,
         defaults: UserDefaults = .standard,
         palette: SolaroPalette = .shared,
         watching: Bool = false) {
        self.directory = directory
        self.defaults = defaults
        self.palette = palette
        self.selectionID = defaults.string(forKey: SolaroPrefs.themePreset.rawValue)
            ?? Self.builtInID
        refresh()
        if watching { startWatching() }
    }

    /// `~/Library/Application Support/SOLARO/Themes` — alongside
    /// `recents.json`, `parameters/` and `crashes/`.
    static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SOLARO/Themes")
    }

    var themesDirectory: URL { directory }

    var selectedEntry: SolaroThemeEntry? {
        entries.first { $0.id == selectionID }
    }

    // MARK: - Discovery

    /// Re-read the folder and re-install the selected theme.
    ///
    /// Called on init, whenever the Appearance pane appears, and from
    /// the directory watcher — so this is also what "live reload"
    /// means: one idempotent function, driven by three triggers.
    func refresh() {
        let user = userEntries()
        // A file wins over the preset of the same name: `nord.json` in
        // the folder is "my Nord", not a second row that loses to the
        // built-in one. Shadowing by removal rather than by lookup
        // order keeps the picker honest — one row per name.
        let shadowed = Set(user.map(\.id))
        let presets = Self.presetEntries().filter { shadowed.contains($0.id) == false }
        entries = Self.builtInEntry() + presets + user
        load(selectionID, userInitiated: false)
    }

    private static func builtInEntry() -> [SolaroThemeEntry] {
        [SolaroThemeEntry(id: builtInID, name: "SOLARO", origin: .builtIn)]
    }

    private static func presetEntries() -> [SolaroThemeEntry] {
        SolaroThemeCatalog.presets.map { preset in
            // The display name comes from the preset's own JSON, so
            // the name a user sees and the name in the file they could
            // copy are the same string.
            let name = (try? SolaroThemeFile.parse(Data(preset.json.utf8)))?
                .theme.name ?? preset.id
            return SolaroThemeEntry(id: preset.id, name: name, origin: .preset)
        }
    }

    /// `*.json` in the Themes folder, sorted by name. A file shadows a
    /// preset of the same stem.
    private func userEntries() -> [SolaroThemeEntry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                // The display name is the file's `name`, falling back
                // to the filename. Parsing the whole file to get a
                // label is cheap (a theme is a few hundred bytes) and
                // means a broken file still lists, under its filename,
                // rather than disappearing from the picker with no
                // explanation.
                let stated = (try? SolaroThemeFile.parse(Data(contentsOf: url)))?
                    .theme.name
                return SolaroThemeEntry(id: stem,
                                        name: stated ?? stem,
                                        origin: .userFile(url))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Selection

    /// Pick a theme. Persists the choice and installs it immediately —
    /// which is what makes clicking through the picker a live preview
    /// rather than a commitment.
    func select(_ id: String) {
        selectionID = id
        defaults.set(id, forKey: SolaroPrefs.themePreset.rawValue)
        load(id, userInitiated: true)
    }

    /// Install the theme with this id.
    ///
    /// Every failure path ends at the built-in palette with a message,
    /// never at a half-applied one: `SolaroThemeTokens.overriding`
    /// starts from the built-ins, so a file that names three colours
    /// changes three colours and a file that names none changes none.
    ///
    /// `userInitiated` distinguishes a click in Settings from a reload
    /// the watcher triggered. Only a click is allowed to change the
    /// window appearance: having a background file write yank someone
    /// out of the light mode they chose would be a worse surprise than
    /// a dark palette in a light window.
    private func load(_ id: String, userInitiated: Bool) {
        var collected: [SolaroThemeIssue] = []
        var file: SolaroThemeFile?

        switch source(for: id) {
        case .none:
            // A theme that was selected and then deleted or renamed.
            // Keep the selection so that putting the file back
            // restores it, and say which name is missing.
            if id != Self.builtInID {
                collected.append(SolaroThemeIssue(
                    key: nil,
                    detail: "theme \"\(id)\" was not found in \(directory.path) "
                            + "— showing SOLARO's own palette"))
            }
        case .some(let data):
            do {
                let parsed = try SolaroThemeFile.parse(data.bytes)
                file = parsed.theme
                collected = parsed.issues
            } catch {
                collected.append(SolaroThemeIssue(
                    key: nil,
                    detail: "\(data.label) could not be read: "
                            + String(describing: error)
                            + " — showing SOLARO's own palette"))
            }
        }

        let overrides = file?.colors ?? [:]
        let tokens = SolaroThemeTokens.builtIn.overriding(overrides)
        palette.install(tokens)

        issues = collected
        statedTokenCount = overrides.count
        pinnedAppearance = file?.appearance

        if userInitiated, let wanted = file?.appearance {
            // Written rather than applied: `RootView` and the Settings
            // pane both watch this key through `@AppStorage`, so one
            // write reaches the NSAppearance, the SwiftUI colour
            // scheme and the Appearance picker's own selection.
            defaults.set(wanted.rawValue, forKey: SolaroPrefs.theme.rawValue)
        }

        // At launch there is no Settings window to read `issues`, so a
        // broken theme would otherwise be a silent fallback to the
        // built-in palette — exactly the "why did my theme stop
        // working" report that is impossible to answer.
        for issue in collected {
            SolaroDiagnostics.note("Theme: \(issue.description)")
        }
    }

    private struct Source {
        let bytes: Data
        let label: String
    }

    private func source(for id: String) -> Source? {
        if id == Self.builtInID { return nil }
        // `entries` already dropped any preset a user file shadows, so
        // this finds the file when there is one.
        if let entry = entries.first(where: { $0.id == id }),
           case .userFile(let url) = entry.origin {
            guard let bytes = try? Data(contentsOf: url) else { return nil }
            return Source(bytes: bytes, label: url.lastPathComponent)
        }
        if let preset = SolaroThemeCatalog.preset(id: id) {
            return Source(bytes: Data(preset.json.utf8), label: "\(id) (built-in preset)")
        }
        return nil
    }

    // MARK: - Live reload

    /// Watch the Themes folder so a hand-edit applies on save.
    ///
    /// `ExternalFileWatcher` is the app's one file-watching mechanism
    /// (kqueue, coalesced on the main actor) and already watches
    /// directories for the editor, so themes reuse it rather than
    /// adding a second. The directory alone is not enough: a kqueue on
    /// a directory fires on create/delete/rename but not on a write
    /// *inside* an existing file, so each theme file is watched too.
    private func startWatching() {
        let watcher = ExternalFileWatcher()
        watcher.onChange = { [weak self] _ in
            self?.refresh()
            self?.rearmWatcher()
        }
        self.watcher = watcher
        rearmWatcher()
    }

    private func rearmWatcher() {
        guard let watcher else { return }
        var paths: [URL] = []
        if FileManager.default.fileExists(atPath: directory.path) {
            paths.append(directory)
        }
        for entry in entries {
            if case .userFile(let url) = entry.origin { paths.append(url) }
        }
        watcher.watch(paths)
    }

    /// Whether live reload is armed. Exposed for the test that asserts
    /// the folder is actually being watched rather than that the call
    /// did not throw.
    var watchedPathCount: Int { watcher?.watchedCount ?? 0 }

    // MARK: - The folder itself

    /// Create the Themes folder if needed, drop a worked example in it
    /// when it holds no themes yet, and show it in the Finder.
    ///
    /// The example is the built-in palette with all 26 tokens spelled
    /// out: it documents the schema as something editable, and a user
    /// who deletes the keys they do not care about is left with a legal
    /// partial theme.
    func revealThemesFolder() {
        seedExampleIfFolderIsEmpty()
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    /// The half of `revealThemesFolder` that touches files. Separate so
    /// it can be tested without a Finder window opening on whoever is
    /// running the suite.
    ///
    /// Returns the example's URL when it wrote one.
    @discardableResult
    func seedExampleIfFolderIsEmpty() -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            guard userEntries().isEmpty else { return nil }
            let example = directory.appendingPathComponent("Example.json")
            guard FileManager.default.fileExists(atPath: example.path) == false
            else { return nil }
            try Data(SolaroThemeTokens.exampleJSON().utf8)
                .write(to: example, options: [.atomic])
            refresh()
            rearmWatcher()
            return example
        } catch {
            SolaroDiagnostics.warn("the themes folder", error: error)
            return nil
        }
    }
}

// MARK: - Settings UI

/// Settings → Appearance, beneath the Light / Dark / Match system
/// picker (GitLab #269).
///
/// Selecting a row installs it at once, so clicking down the list is
/// the live preview the issue asked for — there is no Apply button and
/// nothing to commit. What the user sees when their JSON is wrong is
/// here too: the row still lists (under its filename, since a file
/// that will not parse has no name to show), and the problems are
/// spelled out under the picker, one line per bad key.
struct ThemePresetPicker: View {

    @State private var store = SolaroThemeStore.shared

    var body: some View {
        Picker("Theme preset", selection: Binding(
            get: { store.selectionID },
            set: { store.select($0) }
        )) {
            ForEach(store.entries) { entry in
                Text(label(for: entry)).tag(entry.id)
            }
        }
        HStack(spacing: SolaroSpace.s) {
            Button("Reveal Themes Folder…") { store.revealThemesFolder() }
            Button("Reload") { store.refresh() }
            Spacer()
        }
        if store.issues.isEmpty {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(store.issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.description,
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(SolaroColor.stateWarn)
                }
                Text("Everything a theme does not set keeps SOLARO's own colour.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func label(for entry: SolaroThemeEntry) -> String {
        switch entry.origin {
        case .builtIn:  return "\(entry.name) (built-in)"
        case .preset:   return entry.name
        case .userFile: return "\(entry.name) — my themes"
        }
    }

    /// The honest summary of a partial theme: how much of the palette
    /// is the file's and how much is still SOLARO's.
    private var summary: String {
        guard store.selectionID != SolaroThemeStore.builtInID else {
            return "Drop a JSON theme into the Themes folder to add your own. "
                 + "Any key you leave out keeps SOLARO's colour."
        }
        let total = SolaroColorToken.allCases.count
        return "Sets \(store.statedTokenCount) of \(total) colours; "
             + "the rest are SOLARO's."
    }
}
