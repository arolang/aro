// ============================================================
// BuildOptions.swift
// SOLARO — what `aro build` is asked for (#763)
// ============================================================
//
// The CLI can turn a project into a native binary, and the IDE could
// not. Shipping a binary is the end of the workflow the book's own
// stories describe, and the Signing settings tab already collects a
// Team ID *for release builds* — a build surface existed in Settings
// with nothing to drive it.
//
// These are the two choices `aro build` actually takes that a person
// wants to make per build. The rest of its flags are either derived
// (the output path) or not yet worth a control.

import Foundation

/// How a native build should be linked.
enum BuildLinkage: String, CaseIterable, Identifiable, Sendable {
    /// `--static`: the Swift runtime is baked in, one file to copy.
    /// The CLI's default, and the one that matches what people expect
    /// of "build me a binary".
    case `static`
    /// `--dynamic`: the Swift and Foundation libraries are bundled
    /// beside the binary with an rpath of $ORIGIN.
    case dynamic

    var id: String { rawValue }

    var flag: String { "--\(rawValue)" }

    var displayName: String {
        switch self {
        case .static:  return "Static (single file)"
        case .dynamic: return "Dynamic (bundled libraries)"
        }
    }

    var detail: String {
        switch self {
        case .static:
            return "One executable to copy anywhere. On Linux, Foundation is still dynamic."
        case .dynamic:
            return "Puts libswift* and libFoundation* next to the binary."
        }
    }
}

/// One invocation's worth of build settings.
struct BuildOptions: Equatable, Sendable {
    var optimize: Bool = false
    var linkage: BuildLinkage = .static

    /// The flags after `aro build <path>`.
    var arguments: [String] {
        var out: [String] = [linkage.flag]
        if optimize { out.append("--optimize") }
        return out
    }

    /// What the console echoes, so the user can run the same thing in
    /// a terminal — which is the whole point of echoing it.
    func commandLine(projectName: String) -> String {
        (["$ aro build", projectName] + arguments).joined(separator: " ")
    }

    // MARK: - Persistence

    /// The remembered choice, or the defaults on a first build.
    static func remembered() -> BuildOptions {
        let defaults = UserDefaults.standard
        let linkage = defaults.string(forKey: SolaroPrefs.buildLinkage.rawValue)
            .flatMap(BuildLinkage.init(rawValue:)) ?? .static
        return BuildOptions(
            optimize: defaults.bool(forKey: SolaroPrefs.buildOptimize.rawValue),
            linkage: linkage
        )
    }

    func remember() {
        let defaults = UserDefaults.standard
        defaults.set(optimize, forKey: SolaroPrefs.buildOptimize.rawValue)
        defaults.set(linkage.rawValue, forKey: SolaroPrefs.buildLinkage.rawValue)
    }
}
