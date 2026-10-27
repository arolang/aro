// ============================================================
// ToolResolverWorkingDirectoryTests.swift
// ARO Runtime - resolveExecutableDirectory (GitLab #733)
//
// `ToolResolver` itself moved to AROToolchain; this one helper stays in the
// runtime because it resolves against AROWorkingDirectory, so its tests stay
// with the runtime too.
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
import AROToolchain

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
