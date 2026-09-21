// ============================================================
// GitBlameTests.swift
// SOLARO — blame goes through the git monitor (GitLab #772)
// ============================================================
//
// WorkspaceView built its own Process with its own pipe handling for
// git blame, while every other git call in the app already went through
// GitStatusMonitor. Moving it there is what makes it reachable from a
// test at all.

import Testing
import Foundation
@testable import SOLARO

@Suite("Git blame", .serialized)
@MainActor
struct GitBlameTests {

    /// A real repository with one committed file.
    private func repository() throws -> (Project, URL)? {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-blame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        let file = root.appendingPathComponent("main.aro")
        try "Log \"hi\" to the <console>.\n"
            .write(to: file, atomically: true, encoding: .utf8)

        func git(_ args: [String]) throws -> Int32 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["git"] + args
            task.currentDirectoryURL = root
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        }
        guard (try? git(["init", "-q"])) == 0 else {
            try? FileManager.default.removeItem(at: root)
            return nil          // no git on this machine; nothing to test
        }
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["config", "user.name", "Test"])
        _ = try git(["add", "main.aro"])
        _ = try git(["commit", "-q", "-m", "first"])
        return (Project(rootPath: root), file)
    }

    @Test func blamingATrackedFileReturnsItsLines() async throws {
        guard let (project, file) = try repository() else { return }
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let monitor = GitStatusMonitor()
        let output = await monitor.blame(path: file.path, in: project)
        #expect(output.contains("Log \"hi\" to the <console>."))
        #expect(output.contains("Test"))
    }

    @Test func blamingSomethingGitCannotExplainSaysWhy() async throws {
        guard let (project, _) = try repository() else { return }
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let monitor = GitStatusMonitor()
        let output = await monitor.blame(
            path: project.rootPath.appendingPathComponent("absent.aro").path,
            in: project)
        // One consumer, which renders a string either way — so a
        // failure is a sentence, not an empty pane.
        #expect(output.contains("git blame failed"))
    }
}
