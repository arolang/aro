// ============================================================
// ToolResolverTests.swift
// ARO CLI - ToolResolver Unit Tests (#214)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

// MARK: - ToolResolver.findTool Tests

@Suite("ToolResolver.findTool Tests")
struct ToolResolverFindToolTests {

    @Test("Finds common system tool via which lookup")
    func testFindsCommonTool() {
        // 'ls' exists on all Unix systems
        #if !os(Windows)
        let result = ToolResolver.findTool("ls")
        #expect(result != nil)
        #expect(result?.hasSuffix("/ls") == true)
        #endif
    }

    @Test("Returns nil for nonexistent tool")
    func testNonexistentTool() {
        let result = ToolResolver.findTool("this-tool-definitely-does-not-exist-xyz")
        #expect(result == nil)
    }

    @Test("Returns nil for nonexistent tool with fallbacks that also don't exist")
    func testNonexistentWithBadFallbacks() {
        let result = ToolResolver.findTool(
            "no-such-tool",
            fallbackPaths: ["/nonexistent/path/a", "/nonexistent/path/b"]
        )
        #expect(result == nil)
    }

    @Test("Environment variable override takes priority")
    func testEnvOverridePriority() throws {
        // Use a known executable for the env override
        #if !os(Windows)
        let knownPath = "/usr/bin/true"
        guard FileManager.default.isExecutableFile(atPath: knownPath) else {
            return  // Skip if /usr/bin/true doesn't exist
        }

        let result = ToolResolver.findTool(
            "this-should-be-ignored",
            envOverride: "_ARO_TEST_TOOL_PATH",
            fallbackPaths: ["/also/ignored"],
            environment: ["_ARO_TEST_TOOL_PATH": knownPath]
        )
        #expect(result == knownPath)
        #endif
    }

    @Test("Empty env override is ignored")
    func testEmptyEnvIgnored() {
        let result = ToolResolver.findTool(
            "this-should-not-exist-at-all",
            envOverride: "_ARO_TEST_EMPTY",
            environment: ["_ARO_TEST_EMPTY": ""]
        )
        #expect(result == nil)
    }

    @Test("Env override with nonexistent path falls through to which")
    func testEnvOverrideNonexistentFallsThrough() {
        #if !os(Windows)
        // Should fall through to which and find 'ls'
        let result = ToolResolver.findTool(
            "ls",
            envOverride: "_ARO_TEST_BAD",
            environment: ["_ARO_TEST_BAD": "/nonexistent/binary"]
        )
        #expect(result != nil)
        #endif
    }

    @Test("Fallback paths are used when which fails")
    func testFallbackPathsUsed() {
        #if !os(Windows)
        // Use a tool name that won't be on PATH, but provide a valid fallback
        let result = ToolResolver.findTool(
            "no-such-command-in-path",
            fallbackPaths: ["/nonexistent", "/usr/bin/true"]
        )
        #expect(result == "/usr/bin/true")
        #endif
    }

    @Test("First valid fallback wins")
    func testFirstFallbackWins() {
        #if !os(Windows)
        let result = ToolResolver.findTool(
            "no-such-command",
            fallbackPaths: ["/nonexistent/a", "/usr/bin/true", "/usr/bin/false"]
        )
        #expect(result == "/usr/bin/true")
        #endif
    }
}

// MARK: - ToolResolver.directoryOf Tests

@Suite("ToolResolver.directoryOf Tests")
struct ToolResolverDirectoryOfTests {

    @Test("Returns parent directory of file path")
    func testDirectoryOfFile() {
        let result = ToolResolver.directoryOf("/usr/local/bin/tool")
        #expect(result == "/usr/local/bin")
    }

    @Test("Returns parent directory of nested path")
    func testDirectoryOfNested() {
        let result = ToolResolver.directoryOf("/a/b/c/d")
        #expect(result == "/a/b/c")
    }

    @Test("Root file returns /")
    func testRootFile() {
        let result = ToolResolver.directoryOf("/file")
        #expect(result == "/")
    }
}

// MARK: - ToolResolver.join Tests

@Suite("ToolResolver.join Tests")
struct ToolResolverJoinTests {

    @Test("Joins base and component")
    func testSimpleJoin() {
        let result = ToolResolver.join("/usr/local", "bin")
        #expect(result == "/usr/local/bin")
    }

    @Test("Joins with file name")
    func testJoinFile() {
        let result = ToolResolver.join("/opt/homebrew/share", "aro")
        #expect(result == "/opt/homebrew/share/aro")
    }
}

// MARK: - ToolResolver.resolveExecutableDirectory Tests

@Suite("ToolResolver.resolveExecutableDirectory Tests")
struct ToolResolverResolveExecDirTests {

    @Test("Absolute path returns its directory")
    func testAbsolutePath() {
        let result = ToolResolver.resolveExecutableDirectory("/usr/local/bin/aro")
        #expect(result == "/usr/local/bin")
    }

    @Test("Relative path is resolved against cwd")
    func testRelativePath() {
        let result = ToolResolver.resolveExecutableDirectory("./some/binary")
        let cwd = FileManager.default.currentDirectoryPath
        #expect(result.hasPrefix("/"))
        // Should end with "some" since "binary" is the file
        #expect(result.hasSuffix("/some"))
        // Should contain the cwd
        #expect(result.contains(URL(fileURLWithPath: cwd).lastPathComponent))
    }
}
