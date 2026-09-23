// ============================================================
// PlatformToolchain.swift
// ARO Package Manager - Platform-correct library names and tool discovery
// ============================================================

import Foundation

// MARK: - Platform Library Naming

/// How a dynamic library is named on the host platform.
///
/// The plugin installer used to default a C/C++ plugin's output to
/// `libplugin.dylib` on every platform, so a Linux build produced a Mach-O
/// filename holding an ELF shared object. `PluginLoader` scans the plugin
/// directory for files whose extension matches the *host's* extension, so on
/// Linux the freshly built library was invisible and the plugin "installed but
/// failed to load" (GitLab #669).
///
/// This is the same decision `ARORuntime/Services/PluginLoader.swift` makes when
/// it looks libraries up. It is spelled out separately here because
/// `AROPackageManager` deliberately depends on nothing but Clibgit2 and Yams —
/// the same reason `PluginInstaller.environmentForExternalToolchain()` carries
/// its own copy of the DYLD strip. The two must agree; the tests in
/// `PlatformToolchainTests` pin the table so a divergence is a test failure
/// rather than a plugin that loads on one platform and not another.
public enum PlatformLibrary {

    /// The dynamic-library extension for the host platform, without the dot.
    public static var dynamicLibraryExtension: String {
        #if os(Windows)
        return "dll"
        #elseif canImport(Darwin)
        return "dylib"
        #else
        return "so"
        #endif
    }

    /// The conventional filename prefix for a dynamic library.
    ///
    /// Unix toolchains expect `lib`; Windows does not use one.
    public static var dynamicLibraryPrefix: String {
        #if os(Windows)
        return ""
        #else
        return "lib"
        #endif
    }

    /// The default output filename for a plugin that does not name one in its
    /// `build.output`, e.g. `libplugin.so` on Linux, `plugin.dll` on Windows.
    public static func defaultPluginLibraryName(base: String = "plugin") -> String {
        "\(dynamicLibraryPrefix)\(base).\(dynamicLibraryExtension)"
    }
}

// MARK: - Toolchain Discovery

/// Finds build tools (`swift`, `clang`, `clang++`, `cargo`, `pip3`) on the host.
///
/// Every build path in the installer hard-coded `/usr/bin/<tool>`. That path
/// does not exist for `swift` on the Linux CI image (the toolchain lives under
/// `/usr/share/swift/usr/bin`), it is not where Homebrew puts `clang` on macOS,
/// and it is meaningless on Windows. `AROCLI.PluginCompiler.resolveSwiftExecutable()`
/// already existed precisely because of the first of those; it now delegates here
/// so there is one table rather than several (GitLab #669).
///
/// `ARORuntime.ToolResolver` does the same job for the runtime and shells out to
/// `which`. This module cannot reach it — `AROPackageManager` depends on nothing
/// but Clibgit2 and Yams — so it scans `PATH` in-process instead, which also
/// avoids a subprocess per lookup.
///
/// Resolution order, first hit wins:
/// 1. an explicit environment override (`SWIFT`, `CC`, `CXX`, `CARGO`, `PIP`),
/// 2. the well-known absolute install locations for that tool,
/// 3. a scan of `PATH`.
///
/// Candidates come before `PATH` so the historical behaviour of preferring
/// `/usr/bin/swift` is preserved exactly; `PATH` is the new fallback that makes
/// a toolchain installed anywhere else work.
public enum ToolchainLocator {

    /// Environment variable that overrides the location of each known tool.
    private static let environmentOverrides: [String: String] = [
        "swift": "SWIFT",
        "clang": "CC",
        "clang++": "CXX",
        "cargo": "CARGO",
        "pip3": "PIP",
    ]

    /// Well-known absolute locations per tool, in preference order.
    private static let knownLocations: [String: [String]] = [
        "swift": [
            "/usr/bin/swift",
            "/usr/local/bin/swift",
            "/usr/share/swift/usr/bin/swift",
            "/opt/swift/usr/bin/swift",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/swift",
        ],
        "clang": [
            "/usr/bin/clang",
            "/usr/local/bin/clang",
            "/opt/homebrew/opt/llvm/bin/clang",
        ],
        "clang++": [
            "/usr/bin/clang++",
            "/usr/local/bin/clang++",
            "/opt/homebrew/opt/llvm/bin/clang++",
        ],
        "cargo": [
            "/usr/local/bin/cargo",
            "/usr/bin/cargo",
        ],
        "pip3": [
            "/usr/bin/pip3",
            "/usr/local/bin/pip3",
            "/opt/homebrew/bin/pip3",
        ],
    ]

    /// Locate a build tool, or `nil` if it is not installed.
    /// - Parameter tool: Bare tool name, e.g. `"swift"` or `"clang++"`.
    public static func find(_ tool: String) -> String? {
        let fileManager = FileManager.default

        if let variable = environmentOverrides[tool],
           let override = ProcessInfo.processInfo.environment[variable],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        // A caller may pass a path rather than a bare name (a plugin's
        // `build.compiler` is free text); honour it as given.
        if tool.contains("/"), fileManager.isExecutableFile(atPath: tool) {
            return tool
        }

        for candidate in knownLocations[tool] ?? [] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return searchPath(for: tool)
    }

    /// Locate a build tool or throw a message the user can act on.
    public static func require(_ tool: String) throws -> String {
        guard let path = find(tool) else {
            throw ToolchainError.notFound(tool)
        }
        return path
    }

    /// Scan `PATH` for an executable named `tool`.
    private static func searchPath(for tool: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PATH"], !path.isEmpty else { return nil }

        #if os(Windows)
        let separator: Character = ";"
        // `PATHEXT` is more general, but every tool we look for is a .exe.
        let names = [tool, "\(tool).exe"]
        #else
        let separator: Character = ":"
        let names = [tool]
        #endif

        let fileManager = FileManager.default
        for directory in path.split(separator: separator) where !directory.isEmpty {
            for name in names {
                let candidate = URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(name).path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }
}

// MARK: - Toolchain Errors

/// A build tool the installer needs is not on this machine
public enum ToolchainError: Error, CustomStringConvertible, Equatable {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let tool):
            return """
                Build tool not found: \(tool)

                Install it, put it on PATH, or point ARO at it with the matching \
                environment variable (SWIFT, CC, CXX, CARGO, PIP).
                """
        }
    }
}
