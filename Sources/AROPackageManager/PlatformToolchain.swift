// ============================================================
// PlatformToolchain.swift
// ARO Package Manager - Platform-correct library names and tool discovery
// ============================================================

import Foundation
import AROToolchain

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
/// `AROPackageManager` deliberately does not depend on `ARORuntime` — the same
/// reason `PluginInstaller.environmentForExternalToolchain()` carries its own
/// copy of the DYLD strip. The two must agree; the tests in
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
/// and it is meaningless on Windows (GitLab #669).
///
/// The candidate table and the search itself now live in `AROToolchain`
/// (GitLab #733). This type carried its own copy because `AROPackageManager`
/// deliberately depends on nothing heavy and so could not reach
/// `ARORuntime.ToolResolver` — `AROToolchain` is a leaf module precisely to end
/// that, and the duplicate table it forced. The name stays because the installer
/// and the plugin compiler both call it.
public enum ToolchainLocator {

    /// Locate a build tool, or `nil` if it is not installed.
    /// - Parameter tool: Bare tool name, e.g. `"swift"` or `"clang++"` — or a
    ///   path to one, since a plugin's `build.compiler` is free text.
    public static func find(_ tool: String) -> String? {
        Toolchain.find(tool)
    }

    /// Locate a build tool or throw a message the user can act on.
    public static func require(_ tool: String) throws -> String {
        guard let path = find(tool) else {
            throw ToolchainError.notFound(tool)
        }
        return path
    }
}

// MARK: - Toolchain Errors

/// A build tool the installer needs is not on this machine
public enum ToolchainError: Error, CustomStringConvertible, Equatable {
    case notFound(String)

    public var description: String {
        ToolchainLookupError.notFound(tool).description
    }

    private var tool: String {
        switch self {
        case .notFound(let tool): return tool
        }
    }
}
