// ============================================================
// PlatformToolchainTests.swift
// ARO Package Manager Tests — platform-correct library names and
// discovered (not assumed) build tools (GitLab #669)
// ============================================================

import Testing
import Foundation
@testable import AROPackageManager

/// The installer defaulted a C/C++ plugin's output to `libplugin.dylib` on every
/// platform and ran `/usr/bin/swift`, `/usr/bin/clang`, `/usr/bin/env cargo`. The
/// first produces a Mach-O filename around an ELF object on Linux, which the
/// runtime's extension-keyed scan never finds; the second does not exist on the
/// Linux CI image, where the toolchain lives under `/usr/share/swift`, and none of
/// it is meaningful on Windows.
@Suite("Platform toolchain (#669)")
struct PlatformToolchainTests {

    // MARK: - Library naming

    @Test("The dynamic library extension follows the host platform")
    func extensionFollowsPlatform() {
        #if os(Windows)
        #expect(PlatformLibrary.dynamicLibraryExtension == "dll")
        #elseif canImport(Darwin)
        #expect(PlatformLibrary.dynamicLibraryExtension == "dylib")
        #else
        #expect(PlatformLibrary.dynamicLibraryExtension == "so")
        #endif
    }

    /// The bug in one line: the default output name must not be `.dylib`
    /// anywhere but Darwin.
    @Test("The default plugin library name is never hard-coded to .dylib")
    func defaultNameIsNotAlwaysDylib() {
        let name = PlatformLibrary.defaultPluginLibraryName()
        #if canImport(Darwin) && !os(Windows)
        #expect(name == "libplugin.dylib")
        #else
        #expect(name != "libplugin.dylib")
        #endif
        #expect(name.hasSuffix(".\(PlatformLibrary.dynamicLibraryExtension)"))
    }

    @Test("Unix platforms keep the lib prefix, Windows does not")
    func libraryPrefixFollowsPlatform() {
        #if os(Windows)
        #expect(PlatformLibrary.dynamicLibraryPrefix.isEmpty)
        #expect(PlatformLibrary.defaultPluginLibraryName() == "plugin.dll")
        #else
        #expect(PlatformLibrary.dynamicLibraryPrefix == "lib")
        #expect(PlatformLibrary.defaultPluginLibraryName().hasPrefix("libplugin."))
        #endif
    }

    @Test("A custom base name is honoured")
    func customBaseName() {
        let name = PlatformLibrary.defaultPluginLibraryName(base: "csv-plugin")
        #expect(name.contains("csv-plugin"))
        #expect(name.hasSuffix(".\(PlatformLibrary.dynamicLibraryExtension)"))
    }

    // MARK: - Tool discovery

    @Test("An unknown tool is not found rather than assumed to be in /usr/bin")
    func unknownToolIsNotFound() {
        #expect(ToolchainLocator.find("aro-tool-that-does-not-exist-\(UUID().uuidString)") == nil)
    }

    @Test("A missing tool throws a message naming it")
    func missingToolThrowsNamedError() {
        let tool = "aro-tool-that-does-not-exist"
        do {
            _ = try ToolchainLocator.require(tool)
            Issue.record("Expected ToolchainError.notFound")
        } catch let error as ToolchainError {
            #expect(error == .notFound(tool))
            #expect(error.description.contains(tool))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A tool on PATH is found without a hard-coded location")
    func findsToolOnPath() throws {
        // `env` is on PATH on every platform this suite runs on, and is not in
        // ToolchainLocator's known-locations table — so a hit proves the PATH
        // scan works rather than the fallback list.
        let found = ToolchainLocator.find("env")
        #expect(found != nil)
        if let found {
            #expect(FileManager.default.isExecutableFile(atPath: found))
        }
    }

    @Test("An absolute path passed as the tool name is honoured")
    func absolutePathIsHonoured() throws {
        let shell = try #require(ToolchainLocator.find("env"))
        #expect(ToolchainLocator.find(shell) == shell)
    }

    @Test("swift resolves to a real executable on this machine")
    func swiftIsResolvable() throws {
        // The suite is running under a Swift toolchain, so this must succeed —
        // including on the Linux CI image where /usr/bin/swift does not exist.
        let swift = try #require(ToolchainLocator.find("swift"))
        #expect(FileManager.default.isExecutableFile(atPath: swift))
    }
}
