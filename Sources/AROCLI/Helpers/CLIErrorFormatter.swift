// ============================================================
// CLIErrorFormatter.swift
// ARO CLI - Error rendering for user-facing output
// ============================================================

import Foundation

/// Renders an error for display to an ARO author.
///
/// String-interpolating an error (`"\(error)"`) prints the *Swift* value, which
/// for an enum is its raw case — so a template failure surfaced as:
///
///     Error: renderError(path: "page.html", message: "Statement compilation
///     error: Expected action verb …, but got identifier(name)")
///
/// exposing internal case names and Swift token spellings that mean nothing to
/// someone writing ARO (GitLab #484). Types conforming to `LocalizedError`
/// already carry a written-for-humans description; this makes sure it is the one
/// that gets printed.
enum CLIErrorFormatter {

    /// The best available human-readable description of `error`.
    static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        // NSError-backed values also carry a usable localizedDescription; the
        // fallback interpolation is last resort for plain enums with no
        // conformance, where the case name is genuinely all there is.
        let localized = error.localizedDescription
        if !localized.isEmpty, !localized.hasPrefix("The operation couldn’t be completed") {
            return localized
        }
        return "\(error)"
    }
}
