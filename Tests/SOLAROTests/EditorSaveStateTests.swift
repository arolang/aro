// ============================================================
// EditorSaveStateTests.swift
// SOLARO — autosave failure state machine (GitLab #532)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Editor save state")
struct EditorSaveStateTests {

    private var fileA: URL { URL(fileURLWithPath: "/tmp/solaro-tests/users.aro") }
    private var fileB: URL { URL(fileURLWithPath: "/tmp/solaro-tests/orders.aro") }

    @Test func startsClean() {
        let state = EditorSaveState()
        #expect(!state.hasFailures)
        #expect(state.failure(for: fileA) == nil)
    }

    @Test func recordsAFailurePerFile() {
        var state = EditorSaveState()
        state.recordFailure(for: fileA, message: "Permission denied")
        #expect(state.hasFailures)
        #expect(state.failure(for: fileA)?.message == "Permission denied")
        // A failure on one file says nothing about another.
        #expect(state.failure(for: fileB) == nil)
    }

    /// Autosave retries on every keystroke, so the same failure
    /// arrives dozens of times a second. Only the first (and any
    /// change of reason) is worth logging.
    @Test func onlyTheFirstIdenticalFailureAsksToBeLogged() {
        var state = EditorSaveState()
        #expect(state.recordFailure(for: fileA, message: "Permission denied") == true)
        #expect(state.recordFailure(for: fileA, message: "Permission denied") == false)
        #expect(state.recordFailure(for: fileA, message: "Permission denied") == false)
        #expect(state.failure(for: fileA)?.attempts == 3)
    }

    @Test func aChangedReasonAsksToBeLoggedAgain() {
        var state = EditorSaveState()
        #expect(state.recordFailure(for: fileA, message: "Permission denied") == true)
        #expect(state.recordFailure(for: fileA, message: "No space left on device") == true)
        #expect(state.failure(for: fileA)?.message == "No space left on device")
    }

    @Test func keepsTheFirstFailureTimestampAcrossRetries() {
        var state = EditorSaveState()
        let start = Date(timeIntervalSince1970: 1_000)
        state.recordFailure(for: fileA, message: "Permission denied", now: start)
        state.recordFailure(for: fileA, message: "Permission denied",
                            now: start.addingTimeInterval(30))
        #expect(state.failure(for: fileA)?.firstFailedAt == start)
    }

    /// The retry story: the next keystroke that lands clears the
    /// banner without any explicit user action.
    @Test func aSuccessfulWriteClearsTheFailure() {
        var state = EditorSaveState()
        state.recordFailure(for: fileA, message: "Permission denied")
        #expect(state.recordSuccess(for: fileA) == true)
        #expect(!state.hasFailures)
        #expect(state.failure(for: fileA) == nil)
    }

    @Test func successOnAHealthyFileChangesNothing() {
        var state = EditorSaveState()
        #expect(state.recordSuccess(for: fileA) == false)
        #expect(!state.hasFailures)
    }

    @Test func closingATabForgetsItsFailure() {
        var state = EditorSaveState()
        state.recordFailure(for: fileA, message: "Permission denied")
        state.recordFailure(for: fileB, message: "Permission denied")
        state.forget(fileA)
        #expect(state.failure(for: fileA) == nil)
        #expect(state.failure(for: fileB) != nil)
    }

    /// Paths reach this from several directions (tab list, LSP
    /// locations, sidecar lookups) — a `/tmp/./x` must not open a
    /// second, invisible failure record for the same file.
    @Test func pathsAreMatchedAfterStandardization() {
        var state = EditorSaveState()
        state.recordFailure(for: URL(fileURLWithPath: "/tmp/solaro-tests/./users.aro"),
                            message: "Permission denied")
        #expect(state.failure(for: fileA) != nil)
        #expect(state.recordSuccess(for: fileA) == true)
    }

    @Test func bannerNamesTheFileAndTheReason() {
        var state = EditorSaveState()
        state.recordFailure(for: fileA, message: "Permission denied")
        let text = EditorSaveState.bannerMessage(
            fileName: fileA.lastPathComponent,
            failure: state.failure(for: fileA)!)
        #expect(text.contains("users.aro"))
        #expect(text.contains("Permission denied"))
        #expect(text.contains("only in memory"))
    }
}

@Suite("Editor writes reach disk", .serialized)
@MainActor
struct EditorWriteTests {

    /// End-to-end over the real write path: a writable file saves and
    /// leaves no failure behind.
    @Test func writingAWritableFileSucceedsAndStaysClean() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("main.aro")
        try "original".write(to: file, atomically: true, encoding: .utf8)

        let controller = WorkspaceController(project: Project(rootPath: dir))
        #expect(controller.writeToDisk("edited", to: file) == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited")
        #expect(!controller.saveState.hasFailures)
    }

    /// The bug: a read-only destination used to look like a
    /// successful save. It must now register as a failure the UI can
    /// render, and recover on the next write that lands.
    @Test func aFailedWriteIsRecordedAndThenRecovers() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let controller = WorkspaceController(project: Project(rootPath: dir))
        // A file inside a directory we can't write to: the atomic
        // write's temp-file creation fails.
        let file = dir.appendingPathComponent("readonly.aro")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: dir.path)

        #expect(controller.writeToDisk("edited", to: file) == false)
        #expect(controller.saveState.failure(for: file) != nil)
        // Disk still holds the old bytes — which is exactly what the
        // user needs to be told.
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: dir.path)
        #expect(controller.writeToDisk("edited", to: file) == true)
        #expect(controller.saveState.failure(for: file) == nil)
    }
}
