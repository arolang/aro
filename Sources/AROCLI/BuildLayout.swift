// ============================================================
// BuildLayout.swift
// ARO CLI - Native build path layout
// ============================================================
//
// Extracted from BuildCommand (#354): the "where does everything go" math used
// to live inline in `BuildCommand.run()`. It bundles binary-layout and
// platform-flag concerns (the Windows `.exe` suffix, `.build` intermediate
// paths, managed-plugin source/output directories) that the issue called out as
// tangled into the command. Pulling it into a value type keeps `BuildCommand` a
// thin coordinator and makes the path rules independently readable.
//
// Behaviour is intentionally identical to the previous inline version: the same
// `--output` resolution, the same intermediate naming keyed off the binary's
// basename, and the same plugin-dir candidate probing.

import Foundation

/// All filesystem paths a native build reads from or writes to, derived once
/// from the discovered application root and the (optional) `--output` argument.
struct BuildLayout {
    /// Final executable path (with a `.exe` suffix on Windows).
    let binaryPath: URL
    /// Application `.build` directory holding intermediates.
    let buildDir: URL
    /// Intermediate LLVM IR (`.ll`) path.
    let llPath: URL
    /// Intermediate object (`.o`) path as a plain string (matches the linker API).
    let objectPath: String
    /// Directory that ships next to the binary and holds baked managed plugins.
    let outputManagedPluginsDir: URL
    /// Source `Plugins/` (or `plugins/`) directory the managed plugins compile from.
    let sourceManagedPluginsDir: URL
    /// Staging directory for statically-linked plugin artifacts.
    let staticPluginsDir: URL

    /// Compute the layout for a build rooted at `rootPath`.
    ///
    /// - `rootPath`: discovered application root.
    /// - `output`: the raw `--output` value (bare name resolved in-place, or an
    ///   absolute/relative path for out-of-place builds); `nil` falls back to the
    ///   root directory's basename.
    init(rootPath: URL, output: String?) {
        // --output may be a bare name (resolved against rootPath, in-place) or an
        // absolute/relative path (out-of-place). Intermediate .ll/.o always stay in
        // the workspace's .build dir keyed by the binary's filename, never the full
        // path — otherwise an absolute --output produces nested junk dirs.
        let outputArg = output ?? rootPath.lastPathComponent
        let buildDir = rootPath.appendingPathComponent(".build")

        // On Windows, executables need .exe extension
        #if os(Windows)
        let outputArgWithExt = outputArg.hasSuffix(".exe") ? outputArg : outputArg + ".exe"
        #else
        let outputArgWithExt = outputArg
        #endif

        let binaryPath = URL(fileURLWithPath: outputArgWithExt, relativeTo: rootPath)
            .standardizedFileURL
        let intermediateBaseName = binaryPath.deletingPathExtension().lastPathComponent

        self.binaryPath = binaryPath
        self.buildDir = buildDir
        self.llPath = buildDir.appendingPathComponent("\(intermediateBaseName).ll")
        self.objectPath = buildDir.appendingPathComponent("\(intermediateBaseName).o").path
        self.staticPluginsDir = buildDir.appendingPathComponent("static-plugins")

        // Pre-compile managed plugins for inclusion in the binary.
        // Check both "Plugins" (canonical) and "plugins" (convention) — Linux is case-sensitive.
        let pluginsDirCandidates = [
            rootPath.appendingPathComponent("Plugins"),
            rootPath.appendingPathComponent("plugins"),
        ]
        self.sourceManagedPluginsDir = pluginsDirCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? rootPath.appendingPathComponent("Plugins")
        self.outputManagedPluginsDir = binaryPath.deletingLastPathComponent().appendingPathComponent("Plugins")
    }
}
