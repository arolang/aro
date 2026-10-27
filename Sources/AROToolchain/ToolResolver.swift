// ============================================================
// ToolResolver.swift
// AROToolchain - Configurable Tool & Path Discovery
// ============================================================

import Foundation

/// Resolves external tool paths using environment overrides, well-known
/// install locations and a `PATH` scan.
///
/// This is the single implementation of "find a build tool". It used to be
/// nine: `Linker` carried six hand-rolled variants, `PythonLibraryFinder` a
/// seventh, `AROPackageManager.ToolchainLocator` an eighth, and this type a
/// ninth — each with its own candidate list and its own idea of whether a
/// hardcoded path outranks `PATH`. The lists had drifted apart (GitLab #733):
/// Homebrew's LLVM was spelled `llvm@20` in two of them and `llvm` in two
/// others, so the documented `brew install llvm@20` satisfied some probes and
/// not others, and CI papered over it by symlinking one prefix onto the other.
///
/// Search order for every lookup, first hit wins:
/// 1. an environment override (`SWIFT`, `CC`, `CARGO`, `ARO_CARGO_PATH`, …),
/// 2. the name itself, if it is a path to an executable rather than a bare name,
/// 3. `preferredPaths` — locations that deliberately outrank `PATH`,
/// 4. a scan of `PATH`,
/// 5. `fallbackPaths` — locations consulted only if nothing else matched.
///
/// Steps 3 and 5 both exist because the sites being unified disagreed about
/// them, and the disagreement is meaningful rather than accidental. A Python
/// interpreter must be the system one and not whichever virtualenv happens to
/// be active, so its locations are *preferred*; `strip` and `codesign` should
/// come from the active developer toolchain, so theirs are *fallbacks*. One
/// order cannot express both, so `Toolchain`'s table says which a given tool
/// wants.
public enum ToolResolver {

    // MARK: - Tool Discovery

    /// Find an executable tool by name.
    ///
    /// - Parameters:
    ///   - name: The tool name (e.g. `"cargo"`, `"clang"`, `"swiftc"`), or a
    ///     path to one — a plugin's `build.compiler` is free text and may be
    ///     either.
    ///   - envOverride: Environment variable that overrides the lookup.
    ///   - preferredPaths: Locations searched *before* `PATH`.
    ///   - fallbackPaths: Locations searched *after* `PATH`.
    /// - Returns: Absolute path to the tool, or nil if not found.
    public static func findTool(
        _ name: String,
        envOverride: String? = nil,
        preferredPaths: [String] = [],
        fallbackPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        findTool(
            name,
            envOverrides: envOverride.map { [$0] } ?? [],
            preferredPaths: preferredPaths,
            fallbackPaths: fallbackPaths,
            environment: environment
        )
    }

    /// Find an executable tool, honouring several environment overrides in order.
    ///
    /// Two spellings accumulated for the same tool — `SWIFTC` and
    /// `ARO_SWIFTC_PATH`, `CARGO` and `ARO_CARGO_PATH` — because two call sites
    /// each invented one. Both are honoured rather than one being dropped,
    /// which would break whichever script happens to set the other.
    public static func findTool(
        _ name: String,
        envOverrides: [String],
        preferredPaths: [String] = [],
        fallbackPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        // 1. Environment overrides
        for key in envOverrides {
            if let value = environment[key],
               !value.isEmpty,
               FileManager.default.isExecutableFile(atPath: value) {
                return value
            }
        }

        // 2. The caller passed a path rather than a bare name; honour it as given.
        if name.contains("/") || name.contains("\\") {
            if FileManager.default.isExecutableFile(atPath: name) {
                return name
            }
        }

        // 3. Locations that outrank PATH
        if let found = firstExecutable(preferredPaths) {
            return found
        }

        // 4. PATH
        if let found = searchPATH(name, environment: environment) {
            return found
        }

        // 5. Locations consulted only if nothing else matched
        return firstExecutable(fallbackPaths)
    }

    /// Scan `PATH` for an executable named `name`.
    ///
    /// Done in process rather than by spawning `which`/`where`, which is what
    /// this type used to do: a build asks for half a dozen tools and several of
    /// them more than once, and the answer is the same either way.
    public static func searchPATH(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard !name.isEmpty, let path = environment["PATH"], !path.isEmpty else { return nil }

        #if os(Windows)
        let separator: Character = ";"
        // `PATHEXT` is more general, but every tool ARO looks for is a .exe.
        let names = name.lowercased().hasSuffix(".exe") ? [name] : [name, "\(name).exe"]
        #else
        let separator: Character = ":"
        let names = [name]
        #endif

        let fileManager = FileManager.default
        for directory in path.split(separator: separator) where !directory.isEmpty {
            for candidate in names {
                let full = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(candidate).path
                if fileManager.isExecutableFile(atPath: full) {
                    return full
                }
            }
        }
        return nil
    }

    // MARK: - Path Probes

    /// The first of `candidates` that is an executable file.
    public static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The first of `candidates` that exists, file or directory.
    ///
    /// Relative candidates are resolved against `base` (the working directory by
    /// default) so a caller can mix `.build/debug/libARORuntime.a` into a list of
    /// absolute paths, which is exactly what the runtime-library search does.
    public static func firstExistingPath(
        _ candidates: [String],
        relativeTo base: String? = nil
    ) -> String? {
        let fileManager = FileManager.default
        let root = base ?? fileManager.currentDirectoryPath
        for candidate in candidates {
            let full = isAbsolute(candidate)
                ? candidate
                : URL(fileURLWithPath: root).appendingPathComponent(candidate).path
            if fileManager.fileExists(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// The first of `directories` that holds a file named `file`.
    ///
    /// Used to locate a library by the directory it lives in — the answer the
    /// linker wants is the `-L` directory, not the file.
    public static func firstDirectory(containing file: String, in directories: [String]) -> String? {
        directories.first {
            FileManager.default.fileExists(atPath: join($0, file))
        }
    }

    // MARK: - Directory Resolution

    /// Resolve the directory containing a path, using URL APIs instead of NSString.
    public static func directoryOf(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    /// Append a path component to a base path using URL APIs.
    public static func join(_ base: String, _ component: String) -> String {
        URL(fileURLWithPath: base).appendingPathComponent(component).path
    }

    // MARK: - Private

    private static func isAbsolute(_ path: String) -> Bool {
        if path.hasPrefix("/") { return true }
        #if os(Windows)
        // C:\… or \\server\share
        if path.hasPrefix("\\") { return true }
        if path.count >= 3, path.dropFirst().hasPrefix(":\\") { return true }
        #endif
        return false
    }
}
