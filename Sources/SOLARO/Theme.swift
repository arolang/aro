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
// All colors are tuned for the dark appearance. The window forces
// `.preferredColorScheme(.dark)` in SOLAROApp; light-mode support
// is a deliberate non-goal for now (developer tool, dark by default).

import SwiftUI

// MARK: - Palette

enum SolaroColor {

    // --- Surfaces ---

    /// Deepest layer behind everything. Slight blue tilt so the
    /// canvas doesn't feel like a flat blackboard.
    static let backdrop      = Color(red: 0.062, green: 0.075, blue: 0.094)

    /// Sidebars, inspector panels, status bar. One shade lighter
    /// than `backdrop` so the layout reads.
    static let surface       = Color(red: 0.097, green: 0.115, blue: 0.142)

    /// Cards / nodes / popovers sitting on top of surfaces.
    static let surfaceRaised = Color(red: 0.137, green: 0.157, blue: 0.187)

    /// Hairline dividers between zones.
    static let divider       = Color.white.opacity(0.06)

    /// Selected-row tint for sidebar lists.
    static let selection     = Color(red: 0.30, green: 0.42, blue: 0.78).opacity(0.35)

    // --- Foreground ---

    /// Primary body text.
    static let textPrimary   = Color.white.opacity(0.92)
    /// Secondary labels (path metadata, hints).
    static let textSecondary = Color.white.opacity(0.55)
    /// Tertiary labels (empty-state hints, footnotes).
    static let textTertiary  = Color.white.opacity(0.35)

    // --- Brand / accent ---

    /// SOLARO accent used in the wordmark + focus rings.
    static let accent        = Color(red: 0.30, green: 0.62, blue: 0.95)

    /// Status pips. Run-state indicator on the toolbar.
    static let stateOK       = Color(red: 0.27, green: 0.78, blue: 0.42)
    static let stateWarn     = Color(red: 0.95, green: 0.70, blue: 0.20)
    static let stateError    = Color(red: 0.90, green: 0.32, blue: 0.32)

    // --- Action role tints (wireframe note 8467 figure 4) ---

    /// REQUEST (Extract, Retrieve, Parse, Fetch, Pull, Clone) —
    /// data flowing into the program.
    static let roleRequest   = Color(red: 0.34, green: 0.62, blue: 0.95)

    /// OWN (Compute, Validate, Compare, Create, Transform, Stage,
    /// Checkout) — internal transformations.
    static let roleOwn       = Color(red: 0.73, green: 0.47, blue: 0.95)

    /// RESPONSE (Return, Throw) — data flowing out the way it came in.
    static let roleResponse  = Color(red: 0.39, green: 0.81, blue: 0.55)

    /// EXPORT (Publish, Store, Log, Send, Emit, Commit, Push, Tag) —
    /// effects on the outside world.
    static let roleExport    = Color(red: 0.96, green: 0.65, blue: 0.25)

    /// Lookup helper for verbs. Falls back to `textSecondary` when
    /// the verb's role is unknown.
    static func roleColor(forVerb verb: String) -> Color {
        switch verb.lowercased() {
        case "extract", "parse", "retrieve", "fetch", "pull", "clone", "request":
            return roleRequest
        case "compute", "validate", "compare", "create", "transform", "stage",
             "checkout", "accept", "group", "match", "filter", "sort", "merge":
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
    static let wireNeutral = Color.white.opacity(0.35)

    static func wireColor(forPreposition preposition: String?) -> Color {
        guard let preposition else { return wireNeutral }
        switch preposition.lowercased() {
        case "from":    return Color(red: 0.34, green: 0.62, blue: 0.95) // blue
        case "to":      return Color(red: 0.96, green: 0.78, blue: 0.32) // amber
        case "with":    return Color(red: 0.73, green: 0.47, blue: 0.95) // purple
        case "into":    return Color(red: 0.39, green: 0.81, blue: 0.55) // green
        case "against": return Color(red: 0.90, green: 0.32, blue: 0.32) // red
        case "via":     return Color(red: 0.34, green: 0.62, blue: 0.95) // blue
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
