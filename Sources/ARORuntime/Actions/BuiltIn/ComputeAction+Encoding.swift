// ============================================================
// ComputeAction+Encoding.swift
// ARO Runtime - String encoding computations (GitLab #482)
// ============================================================

import Foundation

/// Encoding and escaping primitives for `Compute`.
///
/// ARO's headline use case is contract-first HTTP APIs, but the language had no
/// way to escape or encode a string: no HTML escaping (so rendering a request
/// field into an ARO-0050 template is XSS by construction), no percent-encoding
/// (so building a query string from user input corrupts the URL as soon as the
/// value contains `&`), and no Base64 (so `Authorization: Basic` headers and
/// data URIs are out of reach). The only workarounds were shelling out through
/// `Exec` or writing a plugin — both disproportionate for `url-encode`.
///
/// These are implemented as `Compute` qualifiers to match the existing
/// `uppercase` / `lowercase` / `hash` shape, so there is no new syntax:
///
/// ```aro
/// Compute the <safe: html-escape>     from <user-input>.
/// Compute the <enc:  url-encode>      from <query>.
/// Compute the <dec:  url-decode>      from <raw>.
/// Compute the <b64:  base64-encode>   from <credentials>.
/// Compute the <raw:  base64-decode>   from <b64>.
/// Compute the <tok:  base64url-encode> from <payload>.
/// Compute the <esc:  json-escape>     from <text>.
/// Compute the <out:  replace> from <text> with { find: "-", replace: "_" }.
/// ```
enum StringEncoding {

    // MARK: - HTML

    /// The five characters that must be escaped to embed text in HTML.
    ///
    /// Covers both element content and quoted attribute values: `&`, `<`, `>`,
    /// `"` and `'`. `&` is replaced first, otherwise it would double-escape the
    /// ampersands introduced by the later replacements.
    static func htmlEscape(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for character in input {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - URL

    /// Characters left unescaped by `url-encode`: RFC 3986's unreserved set.
    ///
    /// Deliberately excludes the sub-delimiters (`&`, `=`, `+`, `;`, …) and `/`,
    /// because the common case is encoding a single query *value*, where those
    /// carry structural meaning. Encoding a whole path or URL is not what this
    /// is for.
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// Percent-encodes `input` for use as a single URL query-string value.
    static func urlEncode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
    }

    /// Decodes percent-escapes. Returns the input unchanged if it is not
    /// validly encoded, which keeps the happy-case philosophy: a malformed
    /// value passes through rather than aborting the feature set.
    static func urlDecode(_ input: String) -> String {
        input.removingPercentEncoding ?? input
    }

    // MARK: - Base64

    static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    /// Decodes standard Base64. Returns nil for input that is not valid Base64
    /// or does not decode to UTF-8, so the caller can raise a proper error.
    static func base64Decode(_ input: String) -> String? {
        guard let data = Data(base64Encoded: input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// URL-safe Base64 (RFC 4648 §5): `+` → `-`, `/` → `_`, padding stripped.
    /// This is the variant JWTs and URL-embedded payloads use.
    static func base64URLEncode(_ input: String) -> String {
        base64Encode(input)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ input: String) -> String? {
        var normalized = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore the padding that base64URLEncode stripped.
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return base64Decode(normalized)
    }

    // MARK: - JSON

    /// Escapes `input` for embedding inside a JSON string literal, without the
    /// surrounding quotes. Control characters below 0x20 become `\uXXXX`.
    static func jsonEscape(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        for scalar in input.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
