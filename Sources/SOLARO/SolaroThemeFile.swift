// ============================================================
// SolaroThemeFile.swift
// SOLARO — themes the user can hand-edit (GitLab #269)
// ============================================================
//
// Settings → Appearance offered Light / Dark / Match system, which
// decides which half of every token in `Theme.swift` is used but
// cannot change a single colour. This file is the other axis: the
// palette itself, as data.
//
// Three decisions are encoded here, and each one is about a file a
// human types into rather than a file a program writes.
//
// 1. A theme is a *partial* override. Every key is optional and
//    anything absent keeps the built-in value. A palette has 26
//    tokens; nobody is going to get all 26 right in one sitting, and
//    a format that demands them all would answer a half-finished
//    file with a half-rendered app.
//
// 2. A bad value costs one token, not the file. Hex that will not
//    parse, a key that does not exist, a number where a colour
//    belongs — each is collected as an issue and skipped, and the
//    rest of the file still applies. Only data that is not JSON at
//    all is fatal, because then there is nothing to salvage. The
//    issues are shown to the user; see `SolaroThemeStore`.
//
// 3. Colours are hex strings, because that is what a human can type
//    and what every palette on the internet is already published in.
//    A token takes either one hex string — used in both appearances,
//    which is what a theme like Dracula or Solarized Dark wants — or
//    `{ "light": …, "dark": … }`, which is what the built-in palette
//    is and what a theme meant to follow the system needs. A file may
//    also declare `"appearance": "dark"` so that selecting it pins
//    the window appearance too; otherwise a dark palette would be
//    drawn behind light scrollbars and light menus.
//
// Everything here is pure: no filesystem, no UserDefaults, no
// AppKit state. That is what makes the failure modes testable.

import Foundation
import AppKit

// MARK: - Tokens

/// One addressable colour in the palette. The raw values are the JSON
/// keys, and they are the names `SolaroColor` already exposes so that
/// a theme author and a SOLARO developer are talking about the same
/// thing.
enum SolaroColorToken: String, CaseIterable, Sendable {

    // Surfaces, back to front.
    case backdrop
    case surface
    case surfaceRaised
    case divider
    case selection

    // Foreground.
    case textPrimary
    case textSecondary
    case textTertiary

    // Brand and status.
    case accent
    case stateOK
    case stateWarn
    case stateError

    // Action-role tints — the node stripes on the canvas.
    case roleRequest
    case roleOwn
    case roleResponse
    case roleExport

    // Wire colours by preposition.
    case wireNeutral
    case wireFrom
    case wireTo
    case wireWith
    case wireInto
    case wireAgainst
    case wireVia

    // Editor syntax colours that are not already one of the above.
    // Keywords use `accent`, articles `textTertiary`, prepositions the
    // wire colours — those need no token of their own.
    case syntaxString
    case syntaxNumber
    case syntaxLiteral

    /// Match a key from a hand-edited file.
    ///
    /// Exact `rawValue` first, then a normalised comparison, so
    /// `surface-raised`, `surface_raised` and `SurfaceRaised` all find
    /// `surfaceRaised`. Being strict here would mean reporting a typo
    /// that is not one: the writer of a theme file has no compiler.
    init?(lenient key: String) {
        if let exact = SolaroColorToken(rawValue: key) {
            self = exact
            return
        }
        let wanted = Self.normalise(key)
        guard wanted.isEmpty == false,
              let match = SolaroColorToken.allCases.first(where: {
                  Self.normalise($0.rawValue) == wanted
              })
        else { return nil }
        self = match
    }

    private static func normalise(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Colour values

/// A colour as a theme file carries it: four components in 0…1.
///
/// Not `NSColor` because the built-in palette is defined in full
/// precision and an 8-bit hex round-trip would move it; not `Color`
/// because this type has to be `Equatable` for the merge and the
/// tests, and comparing SwiftUI colours compares providers.
struct SolaroRGBA: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour is not opaque. Used
    /// to write the worked example into the user's Themes folder, so
    /// the schema is documented by a file they can edit rather than
    /// only by prose.
    var hexString: String {
        func byte(_ v: Double) -> Int {
            Int((min(max(v, 0), 1) * 255).rounded())
        }
        let base = String(format: "#%02X%02X%02X",
                          byte(red), byte(green), byte(blue))
        return alpha >= 1 ? base : base + String(format: "%02X", byte(alpha))
    }
}

/// Why a hex string could not be read. Carries enough to tell the
/// user what to change — "6 digits, not 5" is actionable, "invalid
/// colour" is not.
enum SolaroHexError: Error, Equatable, CustomStringConvertible {
    case empty
    case digitCount(Int)
    case notHexadecimal(String)

    var description: String {
        switch self {
        case .empty:
            return "empty colour string"
        case .digitCount(let n):
            return "\(n) hex digits — expected 3, 4, 6 or 8 (#RGB, #RGBA, #RRGGBB, #RRGGBBAA)"
        case .notHexadecimal(let text):
            return "\"\(text)\" is not hexadecimal"
        }
    }
}

extension SolaroRGBA {

    /// Parse `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`, with or
    /// without the `#`, in either case.
    ///
    /// There is no out-of-range value to reject: every hex digit pair
    /// is a byte, and a byte is in range by construction. The
    /// rejections are therefore all about shape — a wrong digit count
    /// or a non-hex character — which is what a typed colour actually
    /// gets wrong.
    static func parse(hex raw: String) throws -> SolaroRGBA {
        var digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.lowercased().hasPrefix("0x") { digits.removeFirst(2) }
        guard digits.isEmpty == false else { throw SolaroHexError.empty }
        guard digits.allSatisfy(\.isHexDigit) else {
            throw SolaroHexError.notHexadecimal(raw)
        }
        let chars = Array(digits)
        func nibble(_ c: Character) -> Double {
            Double(c.hexDigitValue ?? 0) / 15
        }
        func byte(_ hi: Character, _ lo: Character) -> Double {
            // `allSatisfy(\.isHexDigit)` above is what makes these
            // non-nil; defaulting keeps the force-unwrap out of a
            // paint path's call tree.
            let high = hi.hexDigitValue ?? 0
            let low = lo.hexDigitValue ?? 0
            return Double(high * 16 + low) / 255
        }
        switch chars.count {
        case 3:
            return SolaroRGBA(nibble(chars[0]), nibble(chars[1]), nibble(chars[2]))
        case 4:
            return SolaroRGBA(nibble(chars[0]), nibble(chars[1]),
                              nibble(chars[2]), nibble(chars[3]))
        case 6:
            return SolaroRGBA(byte(chars[0], chars[1]),
                              byte(chars[2], chars[3]),
                              byte(chars[4], chars[5]))
        case 8:
            return SolaroRGBA(byte(chars[0], chars[1]),
                              byte(chars[2], chars[3]),
                              byte(chars[4], chars[5]),
                              byte(chars[6], chars[7]))
        default:
            throw SolaroHexError.digitCount(chars.count)
        }
    }
}

/// One token's value across both appearances. A theme that gives a
/// single hex string gets the same colour in both, which is correct
/// for a palette that only makes sense dark (or only light) and is
/// paired with `"appearance"`.
struct SolaroThemeColor: Equatable, Sendable {
    var light: SolaroRGBA
    var dark: SolaroRGBA

    init(light: SolaroRGBA, dark: SolaroRGBA) {
        self.light = light
        self.dark = dark
    }

    init(_ both: SolaroRGBA) {
        self.light = both
        self.dark = both
    }

    func resolved(dark isDark: Bool) -> SolaroRGBA {
        isDark ? dark : light
    }
}

// MARK: - Issues

/// A problem found while reading a theme file.
///
/// Collected rather than thrown one at a time: a hand-edited file
/// tends to have several mistakes, and surfacing one per launch would
/// make fixing a palette a conversation instead of an edit.
/// `Error` only so that it can be a `Result` failure while a file is
/// being read — nothing throws one. The whole point is that these are
/// collected, not propagated.
struct SolaroThemeIssue: Error, Equatable, Sendable, CustomStringConvertible {
    /// The colour key the problem is about, when it is about one.
    let key: String?
    let detail: String

    var description: String {
        guard let key else { return detail }
        return "\(key): \(detail)"
    }
}

// MARK: - The file

/// A parsed theme file.
///
/// Shape:
/// ```json
/// {
///   "name": "Nord",
///   "appearance": "dark",
///   "colors": {
///     "backdrop": "#2E3440",
///     "textPrimary": { "light": "#2E3440", "dark": "#ECEFF4" }
///   }
/// }
/// ```
/// The `colors` wrapper is optional — a file that is just a flat
/// object of colour keys is accepted too, because that is what people
/// write when they copy a palette out of a blog post.
struct SolaroThemeFile: Equatable, Sendable {

    /// Display name. Absent means "use the filename", which the store
    /// does; keeping it optional here means the parser never invents a
    /// name the file did not state.
    var name: String?

    /// Window appearance to pin while this theme is selected, if the
    /// file asks for one. A dark palette with light system chrome
    /// looks broken in a way that is not the palette's fault, so a
    /// theme is allowed to say which half of the system it belongs to.
    var appearance: SolaroTheme?

    var colors: [SolaroColorToken: SolaroThemeColor]

    /// Keys that mean something other than a colour, and so are not
    /// reported as unknown when a file puts its colours at the top
    /// level.
    private static let reservedKeys: Set<String> = [
        "name", "appearance", "colors", "colours",
        "$schema", "comment", "_comment", "//",
    ]

    enum ParseError: Error, CustomStringConvertible {
        case notJSON(String)
        case notAnObject

        var description: String {
            switch self {
            case .notJSON(let why): return "not valid JSON — \(why)"
            case .notAnObject:      return "the top level must be a JSON object"
            }
        }
    }

    /// Read a theme file.
    ///
    /// Throws only when the bytes are not a JSON object: at that point
    /// there is no theme at all, and the caller keeps the built-in
    /// palette. Everything recoverable comes back in `issues` with the
    /// offending token simply absent from `colors`, which is what
    /// makes a partial or partly-wrong file still usable.
    static func parse(_ data: Data) throws -> (theme: SolaroThemeFile,
                                               issues: [SolaroThemeIssue]) {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data,
                                                    options: [.fragmentsAllowed])
        } catch {
            throw ParseError.notJSON((error as NSError).localizedDescription)
        }
        guard let object = root as? [String: Any] else {
            throw ParseError.notAnObject
        }

        var issues: [SolaroThemeIssue] = []
        var theme = SolaroThemeFile(name: nil, appearance: nil, colors: [:])

        if let name = object["name"] as? String,
           name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            theme.name = name
        }

        if let rawAppearance = object["appearance"] {
            if let text = rawAppearance as? String,
               let parsed = SolaroTheme(rawValue:
                    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                theme.appearance = parsed
            } else {
                issues.append(SolaroThemeIssue(
                    key: "appearance",
                    detail: "expected \"light\", \"dark\" or \"system\""))
            }
        }

        // `colors` (or the British spelling) when present, otherwise
        // the top-level object itself.
        let palette: [String: Any]
        let flat: Bool
        if let nested = (object["colors"] ?? object["colours"]) as? [String: Any] {
            palette = nested
            flat = false
        } else if object["colors"] != nil || object["colours"] != nil {
            issues.append(SolaroThemeIssue(
                key: "colors",
                detail: "expected an object of colour keys"))
            palette = [:]
            flat = false
        } else {
            palette = object
            flat = true
        }

        for (key, value) in palette {
            if flat, Self.reservedKeys.contains(key.lowercased()) { continue }
            guard let token = SolaroColorToken(lenient: key) else {
                issues.append(SolaroThemeIssue(
                    key: key,
                    detail: "not a theme colour"
                            + (Self.nearest(to: key).map { " — did you mean \"\($0)\"?" } ?? "")))
                continue
            }
            switch Self.colorValue(value, token: token, key: key) {
            case .success(let color):
                theme.colors[token] = color
            case .failure(let issue):
                issues.append(issue)
            }
        }

        if theme.colors.isEmpty {
            issues.append(SolaroThemeIssue(
                key: nil,
                detail: "no recognised colour keys — the built-in palette is unchanged"))
        }
        return (theme, issues)
    }

    /// One token's value: a hex string, or `{ light:, dark: }`.
    private static func colorValue(_ value: Any,
                                   token: SolaroColorToken,
                                   key: String) -> Result<SolaroThemeColor,
                                                          SolaroThemeIssue> {
        if let text = value as? String {
            do {
                return .success(SolaroThemeColor(try SolaroRGBA.parse(hex: text)))
            } catch {
                return .failure(SolaroThemeIssue(
                    key: key, detail: String(describing: error)))
            }
        }
        if let pair = value as? [String: Any] {
            // Either side may be omitted; the missing one keeps the
            // built-in, which the merge in `SolaroThemeTokens` does.
            // Both omitted is a mistake worth reporting.
            let light = pair["light"].flatMap { $0 as? String }
            let dark = pair["dark"].flatMap { $0 as? String }
            guard light != nil || dark != nil else {
                return .failure(SolaroThemeIssue(
                    key: key,
                    detail: "expected \"light\" and/or \"dark\" hex strings"))
            }
            var resolved: (light: SolaroRGBA?, dark: SolaroRGBA?) = (nil, nil)
            for (label, text) in [("light", light), ("dark", dark)] {
                guard let text else { continue }
                do {
                    let rgba = try SolaroRGBA.parse(hex: text)
                    if label == "light" { resolved.light = rgba } else { resolved.dark = rgba }
                } catch {
                    return .failure(SolaroThemeIssue(
                        key: "\(key).\(label)", detail: String(describing: error)))
                }
            }
            // A one-sided override reuses the built-in for the other
            // appearance. Done here rather than in the merge so that
            // `colors` always holds a complete pair.
            let builtIn = SolaroThemeTokens.builtIn.color(token)
            return .success(SolaroThemeColor(light: resolved.light ?? builtIn.light,
                                             dark: resolved.dark ?? builtIn.dark))
        }
        return .failure(SolaroThemeIssue(
            key: key,
            detail: "expected a hex string like \"#1E2430\", or "
                    + "{ \"light\": …, \"dark\": … }"))
    }

    /// Closest real token to a key that did not match, for the
    /// diagnostic. Cheap prefix/substring match rather than an edit
    /// distance — the common mistake is a half-remembered name, not a
    /// transposition.
    private static func nearest(to key: String) -> String? {
        let probe = key.lowercased().filter { $0.isLetter || $0.isNumber }
        guard probe.count >= 3 else { return nil }
        return SolaroColorToken.allCases.first {
            let candidate = $0.rawValue.lowercased()
            return candidate.hasPrefix(probe) || probe.hasPrefix(candidate)
                || candidate.contains(probe) || probe.contains(candidate)
        }?.rawValue
    }
}

// MARK: - The resolved palette

/// A complete palette: every token has a value for both appearances.
///
/// `builtIn` is the shipping palette, moved here from `SolaroColor`'s
/// static lets verbatim. A theme file produces one of these by
/// overriding the keys it names and inheriting the rest, which is the
/// single mechanism that keeps a partial or broken file from leaving
/// the app monochrome: there is no code path that yields a palette
/// with a hole in it.
struct SolaroThemeTokens: Equatable, Sendable {

    private var colors: [SolaroColorToken: SolaroThemeColor]

    init(colors: [SolaroColorToken: SolaroThemeColor]) {
        self.colors = colors
    }

    /// The value for a token, falling back to the built-in. The
    /// fallback cannot fire for a palette built by `overriding`, and
    /// `builtInCoversEveryToken` asserts it cannot fire for `builtIn`
    /// either; it exists so that no caller has to handle a nil colour.
    func color(_ token: SolaroColorToken) -> SolaroThemeColor {
        if let own = colors[token] { return own }
        if let fallback = Self.builtInColors[token] { return fallback }
        // Unreachable while the test above passes. A mid-grey is still
        // better than a crash in a paint path.
        return SolaroThemeColor(SolaroRGBA(0.5, 0.5, 0.5))
    }

    /// This palette with `overrides` applied on top. Keys not named
    /// keep their current value.
    func overriding(
        _ overrides: [SolaroColorToken: SolaroThemeColor]
    ) -> SolaroThemeTokens {
        var merged = colors
        for (token, color) in overrides { merged[token] = color }
        return SolaroThemeTokens(colors: merged)
    }

    /// Which tokens this palette states explicitly — what the Settings
    /// pane counts when it says "overrides 9 of 26 colours".
    var statedTokens: Set<SolaroColorToken> { Set(colors.keys) }

    static let builtIn = SolaroThemeTokens(colors: builtInColors)

    /// The shipping palette. Values are the ones `SolaroColor` carried
    /// before themes existed, to the digit, so installing no theme
    /// renders exactly what the previous release did.
    private static let builtInColors: [SolaroColorToken: SolaroThemeColor] = [
        // Surfaces. Slight blue tilt on the dark side so the canvas
        // doesn't read as a flat blackboard.
        .backdrop: SolaroThemeColor(
            light: SolaroRGBA(0.961, 0.965, 0.973),
            dark:  SolaroRGBA(0.062, 0.075, 0.094)),
        .surface: SolaroThemeColor(
            light: SolaroRGBA(1.000, 1.000, 1.000),
            dark:  SolaroRGBA(0.097, 0.115, 0.142)),
        .surfaceRaised: SolaroThemeColor(
            light: SolaroRGBA(0.945, 0.949, 0.957),
            dark:  SolaroRGBA(0.137, 0.157, 0.187)),
        .divider: SolaroThemeColor(
            light: SolaroRGBA(0, 0, 0, 0.10),
            dark:  SolaroRGBA(1, 1, 1, 0.06)),
        .selection: SolaroThemeColor(
            light: SolaroRGBA(0.30, 0.42, 0.78, 0.20),
            dark:  SolaroRGBA(0.30, 0.42, 0.78, 0.35)),

        // Foreground.
        .textPrimary: SolaroThemeColor(
            light: SolaroRGBA(0, 0, 0, 0.92),
            dark:  SolaroRGBA(1, 1, 1, 0.92)),
        .textSecondary: SolaroThemeColor(
            light: SolaroRGBA(0, 0, 0, 0.62),
            dark:  SolaroRGBA(1, 1, 1, 0.55)),
        .textTertiary: SolaroThemeColor(
            light: SolaroRGBA(0, 0, 0, 0.42),
            dark:  SolaroRGBA(1, 1, 1, 0.35)),

        // Brand and status.
        .accent:     SolaroThemeColor(SolaroRGBA(0.30, 0.62, 0.95)),
        .stateOK:    SolaroThemeColor(SolaroRGBA(0.27, 0.78, 0.42)),
        .stateWarn:  SolaroThemeColor(SolaroRGBA(0.95, 0.70, 0.20)),
        .stateError: SolaroThemeColor(SolaroRGBA(0.90, 0.32, 0.32)),

        // Action-role tints (wireframe note 8467 figure 4).
        .roleRequest:  SolaroThemeColor(SolaroRGBA(0.34, 0.62, 0.95)),
        .roleOwn:      SolaroThemeColor(SolaroRGBA(0.73, 0.47, 0.95)),
        .roleResponse: SolaroThemeColor(SolaroRGBA(0.39, 0.81, 0.55)),
        .roleExport:   SolaroThemeColor(SolaroRGBA(0.96, 0.65, 0.25)),

        // Wires (figure 5).
        .wireNeutral: SolaroThemeColor(
            light: SolaroRGBA(0, 0, 0, 0.30),
            dark:  SolaroRGBA(1, 1, 1, 0.35)),
        .wireFrom:    SolaroThemeColor(SolaroRGBA(0.34, 0.62, 0.95)),
        .wireTo:      SolaroThemeColor(SolaroRGBA(0.96, 0.78, 0.32)),
        .wireWith:    SolaroThemeColor(SolaroRGBA(0.73, 0.47, 0.95)),
        .wireInto:    SolaroThemeColor(SolaroRGBA(0.39, 0.81, 0.55)),
        .wireAgainst: SolaroThemeColor(SolaroRGBA(0.90, 0.32, 0.32)),
        .wireVia:     SolaroThemeColor(SolaroRGBA(0.34, 0.62, 0.95)),

        // Editor syntax.
        .syntaxString:  SolaroThemeColor(SolaroRGBA(0.48, 0.83, 0.45)),
        .syntaxNumber:  SolaroThemeColor(SolaroRGBA(0.96, 0.78, 0.32)),
        .syntaxLiteral: SolaroThemeColor(SolaroRGBA(0.96, 0.78, 0.32)),
    ]

    /// The built-in palette as a theme file, every token spelled out.
    /// Written into the user's Themes folder as `Example.json` so the
    /// schema is documented by something they can edit.
    static func exampleJSON() -> String {
        var lines: [String] = [
            "{",
            "  \"name\": \"Example — a copy of the built-in palette\",",
            "  \"appearance\": \"system\",",
            "  \"_comment\": \"Delete any key to keep SOLARO's value for it. A single hex string applies to both appearances.\",",
            "  \"colors\": {",
        ]
        let tokens = SolaroColorToken.allCases
        for (index, token) in tokens.enumerated() {
            let color = builtIn.color(token)
            let comma = index == tokens.count - 1 ? "" : ","
            if color.light == color.dark {
                lines.append("    \"\(token.rawValue)\": \"\(color.light.hexString)\"\(comma)")
            } else {
                lines.append("    \"\(token.rawValue)\": { \"light\": \"\(color.light.hexString)\", "
                             + "\"dark\": \"\(color.dark.hexString)\" }\(comma)")
            }
        }
        lines.append("  }")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }
}
