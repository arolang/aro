// ============================================================
// GitActionsTests.swift
// ARO Runtime - Git Actions Unit Tests (ARO-0080)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

#if !os(Windows)

// MARK: - GitService Tests

@Suite("GitService Tests")
struct GitServiceTests {

    @Test("resolveRepoPath defaults to cwd when qualifier is nil")
    func testResolveRepoPathNil() {
        let git = GitService.shared
        let result = git.resolveRepoPath(nil)
        #expect(result.path == FileManager.default.currentDirectoryPath)
    }

    @Test("resolveRepoPath defaults to cwd when qualifier is dot")
    func testResolveRepoPathDot() {
        let git = GitService.shared
        let result = git.resolveRepoPath(".")
        #expect(result.path == FileManager.default.currentDirectoryPath)
    }

    @Test("resolveRepoPath defaults to cwd when qualifier is empty")
    func testResolveRepoPathEmpty() {
        let git = GitService.shared
        let result = git.resolveRepoPath("")
        #expect(result.path == FileManager.default.currentDirectoryPath)
    }

    @Test("resolveRepoPath uses absolute path qualifier")
    func testResolveRepoPathAbsolute() {
        let git = GitService.shared
        let result = git.resolveRepoPath("/tmp/my-repo")
        #expect(result.path == "/tmp/my-repo")
    }

    @Test("resolveRepoPath resolves relative path against cwd")
    func testResolveRepoPathRelative() {
        let git = GitService.shared
        let result = git.resolveRepoPath("./subdir/repo")
        #expect(result.path.hasSuffix("/subdir/repo"))
        #expect(result.path.hasPrefix("/"))
    }

    @Test("status returns valid status for current repo")
    func testStatusCurrentRepo() throws {
        let git = GitService.shared
        // The ARO project itself is a git repo
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let status = try git.status(in: cwd)
        #expect(status.branch != nil)
        #expect(status.commit != nil)
    }

    @Test("status throws for non-repository directory")
    func testStatusNonRepo() {
        let git = GitService.shared
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-git-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(throws: GitServiceError.self) {
            try git.status(in: tmpDir)
        }
    }

    @Test("currentBranch returns branch name for current repo")
    func testCurrentBranch() throws {
        let git = GitService.shared
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let branch = try git.currentBranch(in: cwd)
        // We're on a branch (feat/223-git-actions or main)
        #expect(branch != nil)
        #expect(!branch!.isEmpty)
    }

    @Test("log returns entries for current repo")
    func testLog() throws {
        let git = GitService.shared
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let entries = try git.log(limit: 5, in: cwd)
        #expect(!entries.isEmpty)
        #expect(entries.count <= 5)

        let first = entries[0]
        #expect(!first.hash.isEmpty)
        #expect(first.hash.count == 40)
        #expect(first.short.count == 7)
        #expect(!first.message.isEmpty)
    }

    @Test("log respects limit parameter")
    func testLogLimit() throws {
        let git = GitService.shared
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let one = try git.log(limit: 1, in: cwd)
        let three = try git.log(limit: 3, in: cwd)
        #expect(one.count == 1)
        #expect(three.count == 3)
    }
}

// MARK: - GitStatus Result Tests

@Suite("GitStatus Result Tests")
struct GitStatusResultTests {

    @Test("GitStatus asDictionary includes all fields")
    func testAsDictionary() {
        let status = GitStatus(
            branch: "main",
            commit: "abc123",
            clean: true,
            files: []
        )
        let dict = status.asDictionary
        #expect(dict["branch"] as? String == "main")
        #expect(dict["commit"] as? String == "abc123")
        #expect(dict["clean"] as? Bool == true)
    }

    @Test("GitStatus asDictionary omits nil branch/commit")
    func testAsDictionaryNils() {
        let status = GitStatus(branch: nil, commit: nil, clean: false, files: [["path": "file.txt", "status": "modified"]])
        let dict = status.asDictionary
        #expect(dict["branch"] == nil)
        #expect(dict["commit"] == nil)
        #expect(dict["clean"] as? Bool == false)
    }
}

// MARK: - GitCommitResult Tests

@Suite("GitCommitResult Tests")
struct GitCommitResultTests {

    @Test("GitCommitResult asDictionary includes all fields")
    func testAsDictionary() {
        let result = GitCommitResult(hash: "abc123def", short: "abc123d", message: "test commit", author: "Test")
        let dict = result.asDictionary
        #expect(dict["hash"] as? String == "abc123def")
        #expect(dict["short"] as? String == "abc123d")
        #expect(dict["message"] as? String == "test commit")
        #expect(dict["author"] as? String == "Test")
    }
}

// MARK: - GitLogEntry Tests

@Suite("GitLogEntry Tests")
struct GitLogEntryTests {

    @Test("GitLogEntry asDictionary includes all fields")
    func testAsDictionary() {
        let entry = GitLogEntry(
            hash: "abcdef1234567890abcdef1234567890abcdef12",
            short: "abcdef1",
            message: "Initial commit",
            author: "Dev",
            email: "dev@example.com",
            timestamp: "2026-04-29T10:00:00Z"
        )
        let dict = entry.asDictionary
        #expect(dict["hash"] as? String == "abcdef1234567890abcdef1234567890abcdef12")
        #expect(dict["author"] as? String == "Dev")
        #expect(dict["email"] as? String == "dev@example.com")
    }
}

// MARK: - GitServiceError Tests

@Suite("GitServiceError Tests")
struct GitServiceErrorTests {

    @Test("notARepository error description")
    func testNotARepoDescription() {
        let error = GitServiceError.notARepository("/tmp/foo")
        #expect(error.description == "Not a Git repository: /tmp/foo")
    }

    @Test("operationFailed error description")
    func testOperationFailedDescription() {
        let error = GitServiceError.operationFailed(context: "commit", detail: "nothing to commit")
        #expect(error.description == "Git commit: nothing to commit")
    }
}

// MARK: - Git Event Tests

@Suite("Git Event Tests")
struct GitEventTests {

    @Test("GitCommitEvent has correct event type")
    func testCommitEventType() {
        #expect(GitCommitEvent.eventType == "git.commit")
    }

    @Test("GitCommitEvent stores data")
    func testCommitEventData() {
        let event = GitCommitEvent(hash: "abc123", message: "test", author: "Dev")
        #expect(event.hash == "abc123")
        #expect(event.message == "test")
        #expect(event.author == "Dev")
        #expect(event.timestamp <= Date())
    }

    @Test("GitPushEvent has correct event type")
    func testPushEventType() {
        #expect(GitPushEvent.eventType == "git.push")
    }

    @Test("GitPullEvent has correct event type")
    func testPullEventType() {
        #expect(GitPullEvent.eventType == "git.pull")
    }

    @Test("GitCheckoutEvent has correct event type")
    func testCheckoutEventType() {
        #expect(GitCheckoutEvent.eventType == "git.checkout")
    }

    @Test("GitTagEvent has correct event type")
    func testTagEventType() {
        #expect(GitTagEvent.eventType == "git.tag")
    }

    @Test("GitCloneEvent has correct event type")
    func testCloneEventType() {
        #expect(GitCloneEvent.eventType == "git.clone")
    }

    @Test("GitCloneEvent stores url and path")
    func testCloneEventData() {
        let event = GitCloneEvent(url: "https://github.com/test/repo.git", path: "/tmp/repo")
        #expect(event.url == "https://github.com/test/repo.git")
        #expect(event.path == "/tmp/repo")
    }
}

// MARK: - Git Actions Module Tests

@Suite("Git Actions Module Tests")
struct GitActionsModuleTests {

    @Test("GitActionsModule registers all action types")
    func testModuleActions() {
        let actions = GitActionsModule.actions
        #expect(actions.count == 7)

        let verbs = actions.flatMap { $0.verbs }
        #expect(verbs.contains("stage"))
        #expect(verbs.contains("commit"))
        #expect(verbs.contains("pull"))
        #expect(verbs.contains("push"))
        #expect(verbs.contains("clone"))
        #expect(verbs.contains("checkout"))
        #expect(verbs.contains("tag"))
    }

    @Test("Git actions are registered in ActionRegistry")
    func testRegisteredInRegistry() async {
        let registry = ActionRegistry.shared
        #expect(await registry.action(for: "stage") != nil)
        #expect(await registry.action(for: "commit") != nil)
        #expect(await registry.action(for: "clone") != nil)
        #expect(await registry.action(for: "tag") != nil)
    }
}

// MARK: - Stage/Commit Integration Tests

@Suite("Git Stage and Commit Integration Tests")
struct GitStageCommitTests {

    @Test("Stage and commit in a temp repo")
    func testStageAndCommit() throws {
        let git = GitService.shared
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-git-test-\(UUID().uuidString)")

        // Init a bare repo via git CLI
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init", tmpDir.path]
        initProc.standardOutput = FileHandle.nullDevice
        initProc.standardError = FileHandle.nullDevice
        try initProc.run()
        initProc.waitUntilExit()
        guard initProc.terminationStatus == 0 else { return }

        // Configure user for commit
        for args in [["config", "user.email", "test@aro.dev"], ["config", "user.name", "Test"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = tmpDir
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }

        // Create a file
        try "Hello ARO".write(to: tmpDir.appendingPathComponent("test.txt"), atomically: true, encoding: .utf8)

        // Stage
        try git.stage(files: ["."], in: tmpDir)

        // Commit
        let result = try git.commit(message: "Initial commit", in: tmpDir)
        #expect(!result.hash.isEmpty)
        #expect(result.hash.count == 40)
        #expect(result.short.count == 7)
        #expect(result.message == "Initial commit")

        // Verify via status
        let status = try git.status(in: tmpDir)
        #expect(status.clean == true)
        #expect(status.branch != nil)
    }
}

#endif // !os(Windows)
