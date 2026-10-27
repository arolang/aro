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
        // A type that writes its own `description` means it, on every host.
        // Darwin surfaces that sentence through `localizedDescription`;
        // corelibs-foundation does not, so a Linux runner printed
        // "The operation could not be completed. (ARORuntime.ExpressionError
        // error 0.)" where a Mac printed "Undefined variable: x" — an author
        // reading a CI log learned nothing from their program (train:oracle,
        // the sequel to #900). Reading the conformance directly deletes the
        // platform difference instead of special-casing one wording.
        if let described = error as? any CustomStringConvertible {
            return described.description
        }
        // NSError-backed values also carry a usable localizedDescription; the
        // fallback interpolation is last resort for plain enums with no
        // conformance, where the case name is genuinely all there is.
        let localized = error.localizedDescription
        if !localized.isEmpty, !localized.hasPrefix("The operation couldn’t be completed"),
           !localized.hasPrefix("The operation could not be completed") {
            return localized
        }
        return "\(error)"
    }
}
