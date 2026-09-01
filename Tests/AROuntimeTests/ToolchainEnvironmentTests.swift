// ============================================================
// ToolchainEnvironmentTests.swift
// ARORuntime - Tests for the foreign-toolchain environment strip
// ============================================================
//
// The bug this guards against was a GitHub Actions macOS integration
// failure: the job exports DYLD_LIBRARY_PATH so the aro binary can find
// Homebrew's LLVM 20, cargo inherited it, and rustc loaded *our* libLLVM
// instead of its own — `Symbol not found: llvm::DILocation::getImpl`,
// SIGSEGV out of cargo's target-info probe, on every invocation.
//
// The strip itself is pure, so it is covered here. That it repairs the
// crash was verified by reproduction: with DYLD_LIBRARY_PATH pointing at
// llvm@20, `rustc --print=file-names` aborts, and Examples/CSVProcessor
// fails to build; with the strip in place the same example runs green.

#if !os(Windows)

import Testing
import Foundation
@testable import ARORuntime

@Suite("ToolchainEnvironment — dynamic-linker strip")
struct ToolchainEnvironmentTests {

    @Test("Removes every DYLD_* override a child toolchain must not inherit")
    func removesDynamicLinkerOverrides() {
        let stripped = ToolchainEnvironment.forExternalToolchain()

        #expect(stripped["DYLD_LIBRARY_PATH"] == nil)
        #expect(stripped["DYLD_FALLBACK_LIBRARY_PATH"] == nil)
        #expect(stripped["DYLD_INSERT_LIBRARIES"] == nil)
    }

    // PATH is what lets cargo find rustc, and the CI job puts the Swift
    // toolchain and LLVM on it deliberately. Stripping too much would
    // trade a crash for a "cargo not found".
    @Test("Leaves the rest of the environment intact")
    func preservesEverythingElse() {
        let inherited = ProcessInfo.processInfo.environment
        let stripped = ToolchainEnvironment.forExternalToolchain()

        for (name, value) in inherited where !name.hasPrefix("DYLD_") {
            #expect(stripped[name] == value, "\(name) should survive the strip")
        }
    }

    // Linux resolves rustc's LLVM without consulting LD_LIBRARY_PATH, and
    // the Linux CI job sets it to reach libLLVM-20 for other tools — so it
    // is deliberately not stripped. A green GitLab pipeline depends on it.
    @Test("Keeps LD_LIBRARY_PATH, which Linux still needs")
    func preservesLinuxLibraryPath() {
        setenv("LD_LIBRARY_PATH", "/usr/lib/llvm-20/lib", 1)
        defer { unsetenv("LD_LIBRARY_PATH") }

        let stripped = ToolchainEnvironment.forExternalToolchain()

        #expect(stripped["LD_LIBRARY_PATH"] == "/usr/lib/llvm-20/lib")
    }
}

#endif
