// ============================================================
// AroBinaryVersion.swift
// SOLARO — version mismatch check for the resolved aro CLI
// ============================================================
//
// SOLARO shells out to `aro` for run / debug / test / LSP / ask /
// plugins. When the resolved binary's `--version` disagrees with
// the version SOLARO itself was built against (`AROVersion.shortVersion`),
// we surface a non-blocking banner so the user understands why a
// new flag rejects with "Unknown option" — issue #287.
//
// The check runs once per workspace load and caches the result.
// A dismissal is per-banner-fingerprint (path + version pair) so
// after the user dismisses one mismatch they only see it again
// if either side moves.

import Foundation
import SwiftUI
import AROVersion

/// One snapshot of the resolved binary's `--version` output paired
/// with the SOLARO build's matching string. Drives a banner when
/// the two don't match.
struct AroBinaryVersionCheck: Sendable, Equatable {
    let binaryPath: String
    /// Version reported by `aro --version`, or nil if the binary
    /// refused to run / didn't print a version.
    let binaryVersion: String?
    /// `AROVersion.shortVersion` at the moment of the check —
    /// SOLARO's build-time stamp.
    let solaroVersion: String

    var mismatched: Bool {
        guard let bv = binaryVersion else { return true }
        return Self.normalize(bv) != Self.normalize(solaroVersion)
    }

    /// `path|binaryVersion|solaroVersion` — uniquely identifies a
    /// mismatch so a user dismissal sticks across launches without
    /// silencing a *new* mismatch.
    var fingerprint: String {
        "\(binaryPath)|\(binaryVersion ?? "?")|\(solaroVersion)"
    }

    static func normalize(_ s: String) -> String {
        // `aro --version` prints "aro v1.4.3 (sha) built on …" or
        // just "v1.4.3". Trim to the first whitespace-bounded
        // semver-ish token so a build-date suffix doesn't trigger
        // a false positive.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for token in trimmed.split(separator: " ") {
            let t = token.lowercased()
            if t.hasPrefix("v") || t.first?.isNumber == true {
                return t
            }
        }
        return trimmed.lowercased()
    }
}

/// Probes the resolved `aro` binary at most once per project load.
/// Lives outside `ConsoleProcess` so views can read it without
/// pulling the whole `ConsoleProcess` surface through `@Bindable`.
@MainActor
final class AroBinaryProbe: ObservableObject {
    @Published private(set) var result: AroBinaryVersionCheck?

    /// Set by the dismiss button on the banner; the banner hides
    /// itself when the current fingerprint is in here.
    @Published var dismissedFingerprints: Set<String> = []

    func probe(binaryPath: String) {
        let solaroVersion = AROVersion.shortVersion
        // Short-circuit if we already have a result for this exact
        // binary — re-running `aro --version` on every view appear
        // would slow the workspace down for no information gain.
        if let existing = result, existing.binaryPath == binaryPath {
            return
        }
        Task.detached(priority: .utility) {
            let raw = await Self.invokeVersion(at: binaryPath)
            let probe = AroBinaryVersionCheck(
                binaryPath: binaryPath,
                binaryVersion: raw,
                solaroVersion: solaroVersion
            )
            await MainActor.run { [weak self] in
                self?.result = probe
            }
        }
    }

    var shouldShowBanner: Bool {
        guard let r = result, r.mismatched else { return false }
        return !dismissedFingerprints.contains(r.fingerprint)
    }

    func dismissCurrent() {
        guard let r = result else { return }
        dismissedFingerprints.insert(r.fingerprint)
    }

    private static func invokeVersion(at path: String) async -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
        } catch {
            return nil
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Non-blocking yellow banner above the workspace that surfaces a
/// version mismatch between SOLARO and its resolved `aro` CLI.
/// The dismiss button asks `AroBinaryProbe` to remember this
/// fingerprint so the banner doesn't keep coming back — until
/// either side moves.
struct AroBinaryMismatchBanner: View {
    let binaryPath: String
    let binaryVersion: String
    let solaroVersion: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: SolaroSpace.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(SolaroColor.stateWarn)
            VStack(alignment: .leading, spacing: 2) {
                Text("`aro` version mismatch")
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Text("Using `\(displayPath)` (\(binaryVersion)) — SOLARO was built against \(solaroVersion). Some flags may not be recognised. Pick a different binary in Settings → Backends, or rebuild the project's `aro` CLI to match.")
                    .font(SolaroFont.caption)
                    .foregroundStyle(SolaroColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SolaroColor.textTertiary)
            }
            .buttonStyle(.borderless)
            .help("Dismiss this warning for the current versions")
        }
        .padding(.horizontal, SolaroSpace.m)
        .padding(.vertical, SolaroSpace.s)
        .background(SolaroColor.stateWarn.opacity(0.14))
        .overlay(
            Rectangle()
                .fill(SolaroColor.stateWarn.opacity(0.55))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    /// Drop the home prefix so the banner reads cleanly. Falls back
    /// to the full path for non-home binaries.
    private var displayPath: String {
        let home = NSHomeDirectory()
        if binaryPath.hasPrefix(home) {
            return "~" + binaryPath.dropFirst(home.count)
        }
        return binaryPath
    }
}

