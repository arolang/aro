// ============================================================
// Version.swift
// ARO Version Information
// ============================================================
// The version is a BUILD-TIME constant. The release pipeline
// (.github/workflows/build.yml → "Generate version file")
// overwrites this file with the real tag before compiling, so
// shipped binaries report e.g. "0.11.2".
//
// This checked-in fallback is what a plain `swift build` (local
// dev) compiles. It deliberately does NOT shell out to
// `git describe` at runtime: a shipped binary would then run git
// in whatever directory it happens to be launched from (for a
// Finder-launched .app that is `/`), producing volatile values
// like "-dirty" or "unknown" that made SOLARO and the `aro` CLI
// disagree and raised a false version-mismatch banner.

import Foundation

public enum AROVersion {
    /// Version string. A stable "dev" sentinel for un-stamped
    /// (local) builds; the pipeline replaces this with the tag.
    public static let version: String = "dev"

    /// Short commit hash (embedded at build time; "unknown" locally)
    public static let commit: String = "unknown"

    /// Build date in ISO 8601 format (embedded at build time)
    public static let buildDate: String = "unknown"

    /// Whether this is a release build
    public static let isRelease: Bool = {
        !version.contains("-dirty")
            && !version.hasPrefix("unknown")
            && !version.hasPrefix("dev")
    }()

    /// Full version string with commit and build date
    public static var fullVersion: String {
        "\(version) (\(commit)) built on \(buildDate)"
    }

    /// Short version string (just the version)
    public static var shortVersion: String {
        version
    }
}
