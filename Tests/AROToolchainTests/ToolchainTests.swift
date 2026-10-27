// ============================================================
// ToolchainTests.swift
// AROToolchain - The one table of toolchain locations (GitLab #733)
// ============================================================

import Foundation
import Testing
import AROToolchain

/// Tool discovery was implemented nine times with nine candidate lists. These
/// tests pin the properties the single table has to keep: every list that was
/// merged into it is still searched, `PATH` sits where each tool wants it, and
/// the Homebrew LLVM spelling no longer depends on which probe is asking.
@Suite("Toolchain table (#733)")
struct ToolchainTableTests {

    // MARK: - The llvm@20 vs llvm reconciliation

    @Test("Every LLVM tool searches both Homebrew spellings, pinned first")
    func llvmSpellingsAreBothSearched() {
        for tool in ["llc", "llvm-ar", "llvm-objcopy"] {
            let paths = Toolchain.spec(for: tool, environment: [:]).preferredPaths
            let pinned = paths.firstIndex(of: "/opt/homebrew/opt/llvm@20/bin/\(tool)")
            let rolling = paths.firstIndex(of: "/opt/homebrew/opt/llvm/bin/\(tool)")
            #expect(pinned != nil, "\(tool) must look in llvm@20 — the documented brew formula")
            #expect(rolling != nil, "\(tool) must still look in the unversioned llvm prefix")
            if let pinned, let rolling {
                #expect(pinned < rolling, "\(tool): llvm@20 outranks llvm, matching -lLLVM-20")
            }
        }
    }

    @Test("LLVM_PATH comes before every hardcoded prefix")
    func llvmPathWins() {
        let paths = Toolchain.spec(for: "llc", environment: ["LLVM_PATH": "/custom/llvm"]).preferredPaths
        #expect(paths.first == "/custom/llvm/bin/llc")
    }

    @Test("The version-suffixed Debian spellings prefer 20 over 14")
    func debianSuffixOrder() {
        let paths = Toolchain.spec(for: "llvm-objcopy", environment: [:]).preferredPaths
        let twenty = paths.firstIndex(of: "/usr/bin/llvm-objcopy-20")
        let fourteen = paths.firstIndex(of: "/usr/bin/llvm-objcopy-14")
        #expect(twenty != nil && fourteen != nil)
        if let twenty, let fourteen { #expect(twenty < fourteen) }
    }

    // MARK: - The union of the merged lists

    @Test("Candidate paths the old probes carried are all still searched")
    func mergedCandidatesSurvive() {
        // Each of these came from a different hand-rolled list; losing any one
        // of them breaks a machine that used to work.
        let expected: [String: [String]] = [
            "llc": ["/usr/bin/llc", "/usr/local/bin/llc", "/usr/bin/llc-14"],
            "llvm-ar": ["/usr/bin/llvm-ar-20", "/usr/bin/llvm-ar", "/usr/local/bin/llvm-ar"],
            "clang": ["/usr/bin/clang", "/usr/bin/clang-14", "/opt/homebrew/bin/clang", "/usr/local/bin/clang"],
            "clang++": ["/usr/bin/clang++", "/usr/local/bin/clang++"],
            "python3": ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"],
            "pip3": ["/usr/bin/pip3", "/usr/local/bin/pip3", "/opt/homebrew/bin/pip3"],
        ]
        for (tool, candidates) in expected {
            let spec = Toolchain.spec(for: tool, environment: [:])
            let searched = spec.preferredPaths + spec.fallbackPaths
            for candidate in candidates {
                #expect(searched.contains(candidate), "\(tool) no longer searches \(candidate)")
            }
        }
    }

    @Test("swift and swiftc both reach the Linux CI toolchain location")
    func swiftCILocation() {
        for tool in ["swift", "swiftc"] {
            let spec = Toolchain.spec(for: tool, environment: [:])
            let searched = spec.preferredPaths + spec.fallbackPaths
            #expect(searched.contains("/usr/share/swift/usr/bin/\(tool)"))
            #expect(searched.contains("/opt/swift/usr/bin/\(tool)"))
        }
    }

    @Test("cargo keeps every hardcoded rustup and CI location")
    func cargoCandidates() {
        let spec = Toolchain.spec(for: "cargo", environment: [:])
        let searched = spec.preferredPaths + spec.fallbackPaths
        for candidate in [
            "/root/.cargo/bin/cargo", "/usr/local/cargo/bin/cargo",
            "/opt/homebrew/bin/cargo", "/usr/local/bin/cargo", "/usr/bin/cargo",
        ] {
            #expect(searched.contains(candidate), "cargo no longer searches \(candidate)")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(searched.contains("\(home)/.cargo/bin/cargo"))
    }

    // MARK: - Where PATH sits

    @Test("A Python interpreter on PATH does not outrank the system one")
    func pythonPrefersSystem() {
        // A venv's python3 is on PATH; linking against its libpython ties the
        // binary to a directory that gets deleted.
        #expect(!Toolchain.spec(for: "python3", environment: [:]).preferredPaths.isEmpty)
        #expect(Toolchain.spec(for: "python3", environment: [:]).fallbackPaths.isEmpty)
    }

    @Test("strip and codesign take the toolchain's own before /usr/bin")
    func postLinkToolingPrefersPath() {
        for tool in ["strip", "codesign"] {
            let spec = Toolchain.spec(for: tool, environment: [:])
            #expect(spec.preferredPaths.isEmpty, "\(tool) must let PATH win")
            #expect(spec.fallbackPaths == ["/usr/bin/\(tool)"])
        }
    }

    @Test("swiftc lets the activated toolchain on PATH win")
    func swiftcPrefersPath() {
        let spec = Toolchain.spec(for: "swiftc", environment: [:])
        #expect(spec.preferredPaths.isEmpty)
        #expect(!spec.fallbackPaths.isEmpty)
    }

    // `swift build` and `swiftc` have to be the same toolchain: the scratch
    // directory a `swift build` leaves behind is only reusable by the compiler
    // that produced it. Where a machine has two (Xcode's `/usr/bin/swift` plus a
    // swiftly or setup-swift one on PATH), ranking them differently rebuilt
    // every plugin package from scratch on every `aro build` (GitLab #902).
    @Test("swift and swiftc rank PATH the same way")
    func swiftAndSwiftcAgree() {
        let swift = Toolchain.spec(for: "swift", environment: [:])
        let swiftc = Toolchain.spec(for: "swiftc", environment: [:])
        #expect(swift.preferredPaths.isEmpty, "swift must let PATH win, as swiftc does")
        #expect(!swift.fallbackPaths.isEmpty)
        #expect(swift.preferredPaths.isEmpty == swiftc.preferredPaths.isEmpty)
    }

    // An explicit SWIFTC names a toolchain, so the `swift` beside it is the
    // driver that belongs to it — the one piece of `PluginLoader`'s own lookup
    // that PATH cannot express, kept when the two were folded together.
    @Test("An explicit swiftc also fixes which swift is used")
    func swiftFollowsConfiguredSwiftc() {
        for key in ["SWIFTC", "ARO_SWIFTC_PATH"] {
            let spec = Toolchain.spec(for: "swift", environment: [key: "/opt/tc/usr/bin/swiftc"])
            #expect(spec.preferredPaths.first == "/opt/tc/usr/bin/swift", "\(key) was not followed")
        }
    }

    @Test("A swiftc override that is not named swiftc is left to the rest of the lookup")
    func swiftIgnoresUnrelatedSwiftcOverride() {
        let spec = Toolchain.spec(for: "swift", environment: ["SWIFTC": "/opt/tc/usr/bin/swift-driver"])
        #expect(spec.preferredPaths.isEmpty)
    }

    @Test("The linker's clang is the toolchain's, not Homebrew LLVM's")
    func clangPrefersSystem() {
        let paths = Toolchain.spec(for: "clang", environment: [:]).preferredPaths
        let system = paths.firstIndex(of: "/usr/bin/clang")
        let brewLLVM = paths.firstIndex(of: "/opt/homebrew/opt/llvm@20/bin/clang")
        #expect(system == 0, "the SDK-aware clang must come first")
        if let system, let brewLLVM { #expect(system < brewLLVM) }
    }

    // MARK: - Environment overrides

    @Test("Both accumulated spellings of each override are honoured")
    func bothOverrideSpellings() {
        #expect(Toolchain.spec(for: "cargo", environment: [:]).envOverrides == ["CARGO", "ARO_CARGO_PATH"])
        #expect(Toolchain.spec(for: "swiftc", environment: [:]).envOverrides == ["SWIFTC", "ARO_SWIFTC_PATH"])
        #expect(Toolchain.spec(for: "clang", environment: [:]).envOverrides == ["CC", "ARO_CC_PATH"])
        #expect(Toolchain.spec(for: "clang++", environment: [:]).envOverrides == ["CXX", "ARO_CXX_PATH"])
        #expect(Toolchain.spec(for: "swift", environment: [:]).envOverrides == ["SWIFT"])
        #expect(Toolchain.spec(for: "pip3", environment: [:]).envOverrides == ["PIP"])
    }

    @Test("An environment override beats everything else")
    func overrideWins() throws {
        #if !os(Windows)
        let known = "/usr/bin/true"
        try #require(FileManager.default.isExecutableFile(atPath: known))
        let found = Toolchain.find("cargo", environment: [
            "CARGO": known,
            "PATH": "/usr/bin:/bin",
        ])
        #expect(found == known)
        #endif
    }

    // MARK: - Unknown tools

    @Test("An unknown tool is looked up on PATH, not assumed to be in /usr/bin")
    func unknownToolUsesPath() {
        let spec = Toolchain.spec(for: "some-plugin-compiler", environment: [:])
        #expect(spec.preferredPaths.isEmpty)
        #expect(spec.fallbackPaths.isEmpty)
        #expect(spec.envOverrides.isEmpty)
        #expect(Toolchain.find("aro-tool-that-does-not-exist-\(UUID().uuidString)") == nil)
    }

    @Test("A path passed as the tool name is honoured as given")
    func pathAsName() throws {
        #if !os(Windows)
        let known = "/usr/bin/true"
        try #require(FileManager.default.isExecutableFile(atPath: known))
        #expect(Toolchain.find(known) == known)
        #endif
    }

    @Test("resolve falls back to the bare name so the OS can still try")
    func resolveFallsBackToBareName() {
        let tool = "aro-tool-that-does-not-exist-\(UUID().uuidString)"
        #expect(Toolchain.resolve(tool) == tool)
    }

    @Test("require throws a message naming the tool")
    func requireThrowsNamed() {
        let tool = "aro-tool-that-does-not-exist"
        do {
            _ = try Toolchain.require(tool)
            Issue.record("Expected ToolchainLookupError.notFound")
        } catch let error as ToolchainLookupError {
            #expect(error == .notFound(tool))
            #expect(error.description.contains(tool))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Reality check

    @Test("swift resolves to a real executable on this machine")
    func swiftResolvable() throws {
        // The suite runs under a Swift toolchain, so this must succeed —
        // including on the Linux CI image where /usr/bin/swift does not exist.
        let swift = try #require(Toolchain.find("swift"))
        #expect(FileManager.default.isExecutableFile(atPath: swift))
    }

    @Test("Library directories cover Homebrew on both architectures and MacPorts")
    func libraryDirectories() {
        #expect(Toolchain.libraryDirectories == ["/opt/homebrew/lib", "/usr/local/lib", "/opt/local/lib"])
    }
}

// MARK: - Path probes

@Suite("ToolResolver path probes (#733)")
struct ToolResolverPathProbeTests {

    @Test("preferredPaths outrank PATH")
    func preferredBeatsPath() throws {
        #if !os(Windows)
        let found = ToolResolver.findTool(
            "true",
            preferredPaths: ["/usr/bin/false"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(found == "/usr/bin/false")
        #endif
    }

    @Test("fallbackPaths are consulted only after PATH")
    func fallbackAfterPath() throws {
        #if !os(Windows)
        let found = ToolResolver.findTool(
            "true",
            fallbackPaths: ["/usr/bin/false"],
            environment: ["PATH": "/usr/bin:/bin"]
        )
        #expect(found?.hasSuffix("/true") == true)
        #endif
    }

    @Test("PATH is scanned in process, in order")
    func pathScanOrder() {
        #if !os(Windows)
        let found = ToolResolver.searchPATH("true", environment: ["PATH": "/nonexistent:/usr/bin"])
        #expect(found == "/usr/bin/true")
        #expect(ToolResolver.searchPATH("true", environment: [:]) == nil)
        #endif
    }

    @Test("firstExistingPath resolves relative candidates against a base")
    func firstExistingRelative() {
        #if !os(Windows)
        #expect(ToolResolver.firstExistingPath(["bin/true"], relativeTo: "/usr") == "/usr/bin/true")
        #expect(ToolResolver.firstExistingPath(["/nope", "/usr/bin"]) == "/usr/bin")
        #expect(ToolResolver.firstExistingPath([]) == nil)
        #endif
    }

    @Test("firstDirectory names the directory, not the file")
    func firstDirectoryContaining() {
        #if !os(Windows)
        let found = ToolResolver.firstDirectory(containing: "true", in: ["/nope", "/usr/bin"])
        #expect(found == "/usr/bin")
        #expect(ToolResolver.firstDirectory(containing: "true", in: ["/nope"]) == nil)
        #endif
    }
}
