// ============================================================
// TemplateEscaping.swift
// ARO Runtime - Template output escaping (GitLab #476)
// ============================================================

import Foundation

/// How `Print … to the <template>` escapes values for the template being rendered.
///
/// The engine performed no escaping at all, and the language had no escaping
/// primitive either, so rendering a request field into an HTML template was XSS
/// by construction and there was no way to write the safe version. ARO-0050 is
/// explicitly aimed at HTML — its §11.2 is "HTML Page with Loop" and its
/// examples are `layout.html`, `user-profile.html`, `user-list.html`.
///
/// This is *not* the Mustache default, which the syntax resembles: Mustache
/// escapes `{{ }}` and requires `{{{ }}}` to opt out. ARO's `{{ }}` looked like
/// Mustache and behaved like `{{{ }}}` — the worst combination for reader
/// expectations.
///
/// Escaping by default is the only setting that makes the safe path the short
/// path. The opt-out is explicit and per-statement:
///
/// ```aro
/// {{ Print <greeting> to the <template>. }}          (* escaped *)
/// {{ Print <trusted-html> to the <template: raw>. }} (* verbatim, deliberate *)
/// ```
///
/// The opt-out qualifies the *target*, not the value, matching `<console: error>`
/// for stream selection. It cannot qualify the value: result specifiers are
/// resolved as qualifiers or property access by the expression evaluator, so
/// `<trusted-html: raw>` fails as an undefined member before Log runs.
public enum TemplateEscaping: String, Sendable {
    /// No escaping — plain-text templates, terminal output, emails.
    case none

    /// HTML-escape `& < > " '`.
    case html

    /// Chooses the mode for a template path.
    ///
    /// Keyed on the extension, so a `.html` or `.htm` template escapes and a
    /// `.txt` / `.tpl` / `.md` one does not. Extension-based rather than
    /// configurable because it is the one signal always available at the point
    /// the template is loaded, and it matches how `FileFormat.detect` already
    /// resolves write formats.
    public static func forTemplate(path: String) -> TemplateEscaping {
        let lower = path.lowercased()
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
            return .html
        }
        return .none
    }

    /// The qualifier that opts a single value out of escaping.
    ///
    /// Matches the `raw` convention `WriteAction` already uses to bypass a
    /// serialiser, so there is one spelling to learn. Applied to the template
    /// target: `Print <x> to the <template: raw>.`
    public static func isRawQualifier(_ qualifier: String) -> Bool {
        qualifier.lowercased() == "raw"
    }

    /// Applies this escaping mode to `value`.
    public func apply(to value: String) -> String {
        switch self {
        case .none: return value
        case .html: return StringEncoding.htmlEscape(value)
        }
    }
}
