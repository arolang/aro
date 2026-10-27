// ============================================================
// Toolchain.swift
// AROToolchain - The one table of toolchain locations (GitLab #733)
// ============================================================

import Foundation

/// Where to look for one build tool.
public struct ToolSpec: Sendable {
    /// Bare tool name, as it would be typed in a shell.
    public let name: String
    /// Environment variables that override the lookup, in order of precedence.
    public let envOverrides: [String]
    /// Locations that deliberately outrank `PATH`.
    public let preferredPaths: [String]
    /// Locations consulted only after `PATH`.
    public let fallbackPaths: [String]
    /// What to hand the OS when nothing was found — a bare name the loader may
    /// still resolve. `nil` means "report not found" rather than guess.
    public let lastResort: String?

    public init(
        name: String,
        envOverrides: [String] = [],
        preferredPaths: [String] = [],
        fallbackPaths: [String] = [],
        lastResort: String? = nil
    ) {
        self.name = name
        self.envOverrides = envOverrides
        self.preferredPaths = preferredPaths
        self.fallbackPaths = fallbackPaths
        self.lastResort = lastResort
    }
}

/// The toolchain locations ARO knows about, in one place.
///
/// Every `find*` helper that used to carry its own list reads this instead
/// (GitLab #733). The tables below are the *union* of what those lists held, so
/// a machine any of them could cope with is still coped with; where two lists
/// disagreed about order, the comment on the entry says which won and why.
public enum Toolchain {

    // MARK: - LLVM

    /// Homebrew spells the pinned LLVM `llvm@20` and the rolling one `llvm`.
    ///
    /// The probes disagreed about which to look in: `findArchiver` tried
    /// `llvm@20` first, `findLLVMObjcopy` tried `llvm` first, and `findLLC`
    /// never looked in `llvm@20` at all — so the documented
    /// `brew install llvm@20` left `llc` undiscoverable, and CI worked around it
    /// with `ln -sf /opt/homebrew/opt/llvm@20 /opt/homebrew/opt/llvm`.
    ///
    /// One order now, and it prefers the pinned prefix: ARO links `-lLLVM-20`
    /// and `Package.swift` already defaults `LLVM_PATH` to
    /// `/opt/homebrew/opt/llvm@20`, so on a machine carrying both, LLVM 20 is
    /// the one the rest of the build agrees with. `LLVM_PATH` itself comes first
    /// — the same variable the manifest reads, so pointing it somewhere moves
    /// the tools and the link flags together.
    public static func llvmBinDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var directories: [String] = []
        if let prefix = environment["LLVM_PATH"], !prefix.isEmpty {
            directories.append(ToolResolver.join(prefix, "bin"))
        }
        directories += [
            "/opt/homebrew/opt/llvm@20/bin",   // Apple Silicon Homebrew, pinned
            "/opt/homebrew/opt/llvm/bin",      // Apple Silicon Homebrew, rolling
            "/usr/local/opt/llvm@20/bin",      // Intel Homebrew, pinned
            "/usr/local/opt/llvm/bin",         // Intel Homebrew, rolling
            "/usr/lib/llvm-20/bin",            // Debian/Ubuntu llvm-20 package
        ]
        return directories
    }

    /// An LLVM-suffixed tool (`llc`, `llvm-ar`, `llvm-objcopy`): the Homebrew and
    /// Debian LLVM prefixes first, then the system locations, with the
    /// version-suffixed Debian spellings in LLVM-20-before-LLVM-14 order.
    ///
    /// The three lists this replaces each ordered the version suffixes
    /// differently; `-20` before the unversioned name matches the version ARO
    /// links against, so a machine with both uses the matching one.
    static func llvmTool(
        _ name: String,
        windowsPaths: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToolSpec {
        var preferred = llvmBinDirectories(environment: environment).map { ToolResolver.join($0, name) }
        preferred += [
            "/usr/bin/\(name)-20",
            "/usr/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)-14",   // Ubuntu 24.04's default LLVM
        ]
        #if os(Windows)
        preferred = windowsPaths + preferred
        #endif
        return ToolSpec(
            name: name,
            envOverrides: ["ARO_\(name.uppercased().replacingOccurrences(of: "-", with: "_"))_PATH"],
            preferredPaths: preferred
        )
    }

    // MARK: - The table

    /// Everything ARO shells out to during a build, keyed by bare tool name.
    public static func spec(
        for tool: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ToolSpec {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        switch tool {

        // --- LLVM -------------------------------------------------------

        case "llc":
            return llvmTool("llc", windowsPaths: [
                "C:\\Program Files\\LLVM\\bin\\llc.exe",
                "C:\\Program Files (x86)\\LLVM\\bin\\llc.exe",
            ], environment: environment)

        case "llvm-ar":
            return llvmTool("llvm-ar", environment: environment)

        case "llvm-objcopy":
            return llvmTool("llvm-objcopy", environment: environment)

        // --- C / C++ ----------------------------------------------------

        // Deliberately *not* `llvmTool`. The linker wants the toolchain's own
        // clang, which on macOS knows where the SDK is and on Linux is the one
        // Swift's static libraries were built against; Homebrew's LLVM clang is
        // the last resort, not the first choice. That is the order
        // `Linker.computeCompiler` and `ToolchainLocator` already had, and the
        // reason this entry does not share the LLVM prefix list.
        case "clang", "clang++":
            let suffix = tool == "clang++" ? "++" : ""
            return ToolSpec(
                name: tool,
                envOverrides: tool == "clang++" ? ["CXX", "ARO_CXX_PATH"] : ["CC", "ARO_CC_PATH"],
                preferredPaths: [
                    "/usr/bin/clang\(suffix)",
                    "/usr/bin/clang\(suffix)-20",
                    "/usr/bin/clang\(suffix)-14",   // Ubuntu 22.04 LLVM package
                    "/opt/homebrew/bin/clang\(suffix)",
                    "/usr/local/bin/clang\(suffix)",
                ] + llvmBinDirectories(environment: environment).map {
                    ToolResolver.join($0, "clang\(suffix)")
                } + windowsLLVMPaths(for: "clang\(suffix)"),
                lastResort: windowsExecutableName("clang\(suffix)")
            )

        case "gcc", "g++":
            return ToolSpec(
                name: tool,
                preferredPaths: ["/usr/bin/\(tool)", "/usr/local/bin/\(tool)", "/opt/homebrew/bin/\(tool)"]
            )

        // --- Swift ------------------------------------------------------

        // `swift` keeps PATH ahead of the known locations for the same reason
        // `swiftc` does below, and it is not optional: `swift build` writes its
        // compiler identity into the package's scratch directory, so two
        // different `swift` binaries building the same package invalidate each
        // other's work completely.
        //
        // That is what `/usr/bin/swift` ahead of PATH caused. A macOS CI runner
        // has two toolchains — Xcode's at `/usr/bin/swift` (6.1.2) and the one
        // swiftly installed and exported on PATH (6.3.2). The plugin pre-warm
        // and `PluginLoader` both used PATH; `aro build`'s own plugin stage took
        // `/usr/bin/swift`. So every `aro build` of a Swift-plugin example
        // rebuilt all ~370 modules of SwiftSyntax from scratch — over the
        // integration harness's 300s build budget, which reported it as a
        // missing binary (GitLab #902).
        // `SWIFTC` is honoured here too, as the directory it names rather than
        // the file: an explicit compiler path identifies a toolchain, and the
        // `swift` beside it is the driver that belongs to it. `PluginLoader`
        // derived it that way for its own lookup, and that was the one part of
        // its behaviour `PATH` cannot express, so it moves here rather than
        // being dropped. Ahead of `PATH`, like the `SWIFT` override it stands in
        // for.
        case "swift":
            return ToolSpec(
                name: "swift",
                envOverrides: ["SWIFT"],
                preferredPaths: swiftDriverBesideConfiguredSwiftc(environment: environment),
                fallbackPaths: swiftToolchainPaths(for: "swift")
            )

        // `swiftc` keeps PATH ahead of the known locations: `aro plugins
        // rebuild` compiles against whichever toolchain the developer has
        // activated (swiftly, a nightly, setup-swift in CI), and that is the one
        // on PATH. The known locations are the fallback for images where it is
        // installed but not exported.
        case "swiftc":
            return ToolSpec(
                name: "swiftc",
                envOverrides: ["SWIFTC", "ARO_SWIFTC_PATH"],
                fallbackPaths: swiftToolchainPaths(for: "swiftc")
            )

        // --- Rust -------------------------------------------------------

        // PATH first. `produceRustStaticLib` searched the hardcoded list before
        // PATH and `rebuildRust` searched PATH before it; one of the two had to
        // move, and PATH is both this type's documented order and the right
        // answer for rustup, whose `~/.cargo/bin` shim is on PATH by
        // installation. The hardcoded entries remain as fallbacks, so the CI
        // images that only have `/root/.cargo/bin/cargo` still resolve it.
        case "cargo":
            return ToolSpec(
                name: "cargo",
                envOverrides: ["CARGO", "ARO_CARGO_PATH"],
                fallbackPaths: [
                    "\(home)/.cargo/bin/cargo",
                    "/root/.cargo/bin/cargo",
                    "/usr/local/cargo/bin/cargo",
                    "/opt/homebrew/bin/cargo",
                    "/usr/local/bin/cargo",
                    "/usr/bin/cargo",
                ]
            )

        // --- Python -----------------------------------------------------

        // Preferred, not fallback: an interpreter found on PATH is frequently a
        // virtualenv's, and linking a binary against a venv's `libpython` ties
        // the binary to a directory that will be deleted. The system
        // interpreters come first for that reason.
        case "python3":
            return ToolSpec(
                name: "python3",
                preferredPaths: [
                    "/opt/homebrew/bin/python3",
                    "/usr/local/bin/python3",
                    "/usr/bin/python3",
                ]
            )

        case "pip3":
            return ToolSpec(
                name: "pip3",
                envOverrides: ["PIP"],
                preferredPaths: ["/usr/bin/pip3", "/usr/local/bin/pip3", "/opt/homebrew/bin/pip3"]
            )

        // --- Post-link tooling ------------------------------------------

        // PATH first, so an Xcode or toolchain `strip`/`codesign` wins over the
        // system one — the order these two already had.
        case "codesign", "strip", "ar":
            return ToolSpec(name: tool, fallbackPaths: ["/usr/bin/\(tool)"])

        // --- Anything else ----------------------------------------------

        // A plugin's `build.compiler` is free text, so an unknown name is not an
        // error: it is looked up on PATH, or honoured as a path if it is one.
        default:
            return ToolSpec(name: tool)
        }
    }

    // MARK: - Lookup

    /// Locate a build tool, or `nil` if it is not installed.
    public static func find(
        _ tool: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let spec = spec(for: tool, environment: environment)
        return ToolResolver.findTool(
            spec.name,
            envOverrides: spec.envOverrides,
            preferredPaths: spec.preferredPaths,
            fallbackPaths: spec.fallbackPaths,
            environment: environment
        )
    }

    /// Locate a build tool, or fall back to the bare name and let the OS try.
    ///
    /// Several linker probes ended in `return "clang"` rather than failing,
    /// because a PATH the process cannot see may still resolve it. That
    /// behaviour is preserved here rather than at each call site.
    public static func resolve(
        _ tool: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let spec = spec(for: tool, environment: environment)
        if let found = find(tool, environment: environment) { return found }
        return spec.lastResort ?? spec.name
    }

    /// Locate a build tool or throw a message the user can act on.
    public static func require(
        _ tool: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        guard let path = find(tool, environment: environment) else {
            throw ToolchainLookupError.notFound(tool)
        }
        return path
    }

    // MARK: - Library directories

    /// Where a Homebrew/MacPorts/manual install puts shared libraries.
    ///
    /// Used to find the `-L` directory for a library ARO links by name
    /// (`libgit2`), not to find an executable.
    public static let libraryDirectories: [String] = [
        "/opt/homebrew/lib",       // Apple Silicon Homebrew
        "/usr/local/lib",          // Intel Homebrew / manual install
        "/opt/local/lib",          // MacPorts
    ]

    // MARK: - Private

    /// Where a Swift toolchain lands when it is not on PATH. `/usr/bin/swift`
    /// does not exist on the Linux CI image, which installs under
    /// `/usr/share/swift` (GitLab #669).
    /// The `swift` driver sitting next to an explicitly configured `swiftc`.
    ///
    /// Empty unless `SWIFTC`/`ARO_SWIFTC_PATH` names a file called `swiftc`;
    /// a value pointing at something else is left to the rest of the lookup.
    private static func swiftDriverBesideConfiguredSwiftc(
        environment: [String: String]
    ) -> [String] {
        for key in ["SWIFTC", "ARO_SWIFTC_PATH"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            let compiler = URL(fileURLWithPath: value)
            let driver: String
            switch compiler.lastPathComponent {
            case "swiftc": driver = "swift"
            case "swiftc.exe": driver = "swift.exe"
            default: continue
            }
            return [compiler.deletingLastPathComponent().appendingPathComponent(driver).path]
        }
        return []
    }

    private static func swiftToolchainPaths(for tool: String) -> [String] {
        [
            "/usr/bin/\(tool)",
            "/usr/local/bin/\(tool)",
            "/usr/share/swift/usr/bin/\(tool)",
            "/opt/swift/usr/bin/\(tool)",
            "/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/\(tool)",
        ]
    }

    private static func windowsLLVMPaths(for tool: String) -> [String] {
        #if os(Windows)
        return [
            "C:\\Program Files\\LLVM\\bin\\\(tool).exe",
            "C:\\Program Files (x86)\\LLVM\\bin\\\(tool).exe",
        ]
        #else
        _ = tool
        return []
        #endif
    }

    private static func windowsExecutableName(_ tool: String) -> String {
        #if os(Windows)
        return "\(tool).exe"
        #else
        return tool
        #endif
    }
}

// MARK: - Errors

/// A build tool ARO needs is not on this machine.
public enum ToolchainLookupError: Error, CustomStringConvertible, Equatable {
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
