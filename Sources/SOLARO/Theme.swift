// ============================================================
// Theme.swift
// SOLARO — design tokens (Phase 2)
// ============================================================
//
// Centralised palette / typography / spacing tokens so every view
// pulls from the same source of truth. Mirrors the wireframes in
// note 8467: deep-dark backdrop, glass surfaces, role-tinted node
// stripes, preposition-colored wires.
//
// Colors are dynamic: each backing NSColor returns a light or
// dark value based on the current `NSAppearance`. The user picks
// the theme (system / light / dark) in Settings, which writes
// the chosen NSAppearance to NSApp.appearance; the dynamic
// colors below pick up the swap automatically the next time
// SwiftUI evaluates a view body.
//
// The *values* no longer live here. Every token below reads from
// `SolaroPalette.shared`, which starts as the shipping palette
// (`SolaroThemeTokens.builtIn`, same numbers these statics used to
// hold) and can be overridden by a JSON theme file — see
// `SolaroThemeFile.swift` for the format and `SolaroThemeStore.swift`
// for where a theme comes from (GitLab #269). The accessor names and
// types are unchanged, which is the point: ~1300 call sites across
// the app did not have to learn about themes.

import SwiftUI
import AppKit

// MARK: - Palette

enum SolaroColor {

    // --- Surfaces ---

    /// Deepest layer behind everything. Slight blue tilt so the
    /// canvas doesn't feel like a flat blackboard.
    static var backdrop: Color { token(.backdrop) }

    /// Sidebars, inspector panels, status bar. One shade lighter
    /// than `backdrop` so the layout reads.
    static var surface: Color { token(.surface) }

    /// Cards / nodes / popovers sitting on top of surfaces.
    static var surfaceRaised: Color { token(.surfaceRaised) }

    /// Hairline dividers between zones.
    static var divider: Color { token(.divider) }

    /// Selected-row tint for sidebar lists.
    static var selection: Color { token(.selection) }

    // --- Foreground ---

    /// Primary body text.
    static var textPrimary: Color { token(.textPrimary) }
    /// Secondary labels (path metadata, hints).
    static var textSecondary: Color { token(.textSecondary) }
    /// Tertiary labels (empty-state hints, footnotes).
    static var textTertiary: Color { token(.textTertiary) }

    /// One token out of the live palette.
    ///
    /// The palette memoises, so repeated reads of the same token hand
    /// back the same `Color` — which matters because call sites
    /// compare colours for equality (`SyntaxHighlighter` decides
    /// whether an identifier was a verb that way) and SwiftUI colour
    /// equality compares the backing providers, not the components.
    private static func token(_ token: SolaroColorToken) -> Color {
        SolaroPalette.shared.color(token)
    }

    // --- Brand / accent ---

    /// SOLARO accent used in the wordmark + focus rings.
    static var accent: Color { token(.accent) }

    /// Status pips. Run-state indicator on the toolbar.
    static var stateOK: Color    { token(.stateOK) }
    static var stateWarn: Color  { token(.stateWarn) }
    static var stateError: Color { token(.stateError) }

    // --- Action role tints (wireframe note 8467 figure 4) ---

    /// REQUEST (Extract, Retrieve, Parse, Fetch, Pull, Clone) —
    /// data flowing into the program.
    static var roleRequest: Color { token(.roleRequest) }

    /// OWN (Compute, Validate, Compare, Create, Transform, Stage,
    /// Checkout) — internal transformations.
    static var roleOwn: Color { token(.roleOwn) }

    /// RESPONSE (Return, Throw) — data flowing out the way it came in.
    static var roleResponse: Color { token(.roleResponse) }

    /// EXPORT (Publish, Store, Log, Send, Emit, Commit, Push, Tag) —
    /// effects on the outside world.
    static var roleExport: Color { token(.roleExport) }

    // --- Editor syntax ---
    //
    // Keywords use `accent`, articles `textTertiary` and prepositions
    // the wire colours, so only three syntax categories need tokens of
    // their own. They were inline `Color(red:green:blue:)` literals in
    // `SyntaxHighlighter`, which made the one claim the book makes
    // about themes — that they change syntax colours — untrue for
    // strings and numbers.

    /// String literals and string segments.
    static var syntaxString: Color { token(.syntaxString) }
    /// Int and float literals.
    static var syntaxNumber: Color { token(.syntaxNumber) }
    /// `true` / `false` / `nil`.
    static var syntaxLiteral: Color { token(.syntaxLiteral) }

    /// Lookup helper for verbs. Primary source is the live
    /// `aro actions` registry (same data the left-pane Actions
    /// inspector renders), so the editor tint and the inspector
    /// stay in sync as the runtime grows verbs (#?). The static
    /// table below is a bootstrap fallback used in the brief
    /// window before the first `aro actions` invocation
    /// finishes — and as a safety net for tests / previews that
    /// don't run a workspace.
    static func roleColor(forVerb verb: String) -> Color {
        if let role = ActionsRegistry.sharedRole(forVerb: verb) {
            switch role {
            case .request:  return roleRequest
            case .own:      return roleOwn
            case .response: return roleResponse
            case .export:   return roleExport
            // Server-role actions (Start/Stop/etc.) read as
            // effects on the outside world — paint them with the
            // export tint so the canvas hot-spots are
            // visually consistent.
            case .server:   return roleExport
            case .unknown:  return textSecondary
            }
        }
        switch verb.lowercased() {
        case "extract", "parse", "retrieve", "fetch", "pull", "clone", "request",
             "probe":
            return roleRequest
        case "compute", "validate", "compare", "create", "transform", "stage",
             "checkout", "accept", "group", "match", "filter", "sort", "merge",
             "make", "copy", "move", "exists", "stat":
            return roleOwn
        case "return", "throw":
            return roleResponse
        case "publish", "store", "log", "send", "emit", "commit", "push", "tag",
             "stop", "keepalive":
            return roleExport
        default:
            return textSecondary
        }
    }

    // --- Preposition wire colors (wireframe note 8467 figure 5) ---

    /// Wire color by preposition. Matches the connection-typology
    /// legend documented in the wireframe.
    /// Neutral wire color used when a preposition is missing or
    /// unknown. Centralised so callers / tests share one value.
    static var wireNeutral: Color { token(.wireNeutral) }

    static func wireColor(forPreposition preposition: String?) -> Color {
        guard let preposition else { return wireNeutral }
        switch preposition.lowercased() {
        case "from":    return token(.wireFrom)      // blue
        case "to":      return token(.wireTo)        // amber
        case "with":    return token(.wireWith)      // purple
        case "into":    return token(.wireInto)      // green
        case "against": return token(.wireAgainst)   // red
        case "via":     return token(.wireVia)       // blue
        case "for", "at", "by", "on": return wireNeutral
        default: return wireNeutral
        }
    }
}

// MARK: - Typography

enum SolaroFont {

    /// Big wordmark on the welcome / about screen.
    static let wordmark = Font.system(size: 56, weight: .ultraLight, design: .default)

    /// Section headings inside panes (e.g. "Files", "Inspector").
    static let sectionTitle = Font.system(size: 12, weight: .semibold, design: .default)
        .smallCaps()

    /// Default body text in panes.
    static let body = Font.system(size: 13, weight: .regular, design: .default)

    /// Bolder body for selected rows / titles.
    static let bodyBold = Font.system(size: 13, weight: .semibold, design: .default)

    /// Secondary metadata (file paths, counts).
    static let caption = Font.system(size: 11, weight: .regular, design: .default)

    /// Monospaced — the code editor + identifier chips.
    static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    /// Monospaced caption — line numbers, diagnostics.
    static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)

    /// Title used in the workspace toolbar (project breadcrumb).
    static let toolbarTitle = Font.system(size: 14, weight: .medium, design: .default)
}

// MARK: - Spacing & radii

enum SolaroSpace {
    static let xs: CGFloat  = 4
    static let s:  CGFloat  = 8
    static let m:  CGFloat  = 12
    static let l:  CGFloat  = 16
    static let xl: CGFloat  = 24
    static let xxl: CGFloat = 32
}

enum SolaroRadius {
    static let s:  CGFloat = 4
    static let m:  CGFloat = 8
    static let l:  CGFloat = 12
}

// MARK: - View modifiers

/// Backdrop applied to the root content view — deep dark background
/// covering the whole window.
struct SolaroBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(SolaroColor.backdrop)
    }
}

extension View {
    /// Apply the SOLARO root backdrop.
    func solaroBackdrop() -> some View { modifier(SolaroBackdrop()) }
}

/// Cards / nodes wrapped in this modifier get a consistent surface,
/// rounded corners, and hairline border so they read against the
/// backdrop.
struct SolaroCard: ViewModifier {
    var radius: CGFloat = SolaroRadius.m
    func body(content: Content) -> some View {
        content
            .background(SolaroColor.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(SolaroColor.divider, lineWidth: 1)
            )
    }
}

extension View {
    func solaroCard(radius: CGFloat = SolaroRadius.m) -> some View {
        modifier(SolaroCard(radius: radius))
    }
}

// MARK: - Theme

/// User-selectable appearance — written by the Settings panel,
/// read by RootView when applying NSApp.appearance. Stored as a
/// raw string via @AppStorage so it survives across launches.
enum SolaroTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Match system"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Returns the NSAppearance to install on NSApp.appearance.
    /// `nil` means "let the system decide" — that's what `.system`
    /// maps to.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// Returns the equivalent SwiftUI `ColorScheme?` so the root
    /// view can pin its color scheme too — keeps SwiftUI-side
    /// tinting (e.g. accent buttons) in sync with the NSAppearance.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Apply the theme to the running NSApplication. Safe to call
    /// from any actor — bounces to the main actor internally.
    @MainActor static func apply(_ theme: SolaroTheme) {
        NSApp?.appearance = theme.appearance
    }
}
