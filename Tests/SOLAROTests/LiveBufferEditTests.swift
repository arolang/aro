// ============================================================
// LiveBufferEditTests.swift
// SOLARO — LSP features run on the live buffer (GitLab #535)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("Live buffer edits", .serialized)
@MainActor
struct LiveBufferEditTests {

    /// A project directory with one `.aro` file whose disk contents
    /// deliberately differ from the editor buffer we mirror in.
    private func fixture(disk: String) throws -> (WorkspaceController, URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("main.aro")
        try disk.write(to: file, atomically: true, encoding: .utf8)
        return (WorkspaceController(project: Project(rootPath: dir)), file, dir)
    }

    /// The core of the bug: features read the file from disk while the
    /// user's edits live in the buffer.
    @Test func liveTextPrefersTheEditorBufferOverDisk() throws {
        let (controller, file, dir) = try fixture(disk: "on disk\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(controller.liveText(for: file) == "on disk\n")
        controller.liveEditorText[file.standardizedFileURL] = "in the editor\n"
        #expect(controller.liveText(for: file) == "in the editor\n")
    }

    @Test func liveTextFallsBackToDiskForAnUnopenedFile() throws {
        let (controller, file, dir) = try fixture(disk: "on disk\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(controller.liveText(for: file) == "on disk\n")
    }

    /// The LSP mirror has to be fed the live text before a
    /// position-sensitive request, or the server resolves the
    /// position against a stale document.
    @Test func syncPushesTheLiveBufferIntoTheServerMirror() throws {
        let (controller, file, dir) = try fixture(disk: "on disk\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.lsp.didOpen(url: file, text: "on disk\n")
        controller.liveEditorText[file.standardizedFileURL] = "edited\n"
        controller.syncLSPWithLiveText(file)
        #expect(controller.lsp.openDocuments[file] == "edited\n")
    }

    @Test func syncIsANoOpWhenTheMirrorAlreadyMatches() throws {
        let (controller, file, dir) = try fixture(disk: "same\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.lsp.didOpen(url: file, text: "same\n")
        controller.syncLSPWithLiveText(file)
        #expect(controller.lsp.openDocuments[file] == "same\n")
    }

    /// Accepting a completion must produce a ranged buffer edit for
    /// the open editor — not a whole-file swap, which is what wiped
    /// the undo stack.
    @Test func acceptingACompletionQueuesAnUndoableRangedEdit() throws {
        let (controller, file, dir) = try fixture(disk: "Log  to the <console>.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.openFile(file)
        let queued = controller.replaceInOpenBuffer(
            url: file,
            range: NSRange(location: 4, length: 0),
            with: "\"hi\"",
            actionName: "Accept Completion",
            caretOffset: 8)
        #expect(queued == true)

        let edit = try #require(controller.pendingBufferEdit)
        #expect(edit.url == file.standardizedFileURL)
        #expect(edit.range == NSRange(location: 4, length: 0))
        #expect(edit.newString == "\"hi\"")
        #expect(edit.actionName == "Accept Completion")
        #expect(edit.caretOffset == 8)
        // A ranged edit is positional — it must NOT be a whole-file
        // replacement, which is the shape that forces the editor's
        // destructive external-swap branch.
        #expect(edit.oldString.isEmpty)
    }

    @Test func aBufferEditIsRefusedWhenTheFileIsNotTheActiveEditor() throws {
        let (controller, file, dir) = try fixture(disk: "x\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        let other = dir.appendingPathComponent("other.aro")
        try "y\n".write(to: other, atomically: true, encoding: .utf8)
        controller.openFile(file)

        // Caller falls back to the disk path on false.
        #expect(controller.replaceInOpenBuffer(
            url: other, range: NSRange(location: 0, length: 0),
            with: "z", actionName: "Accept Completion") == false)
        #expect(controller.pendingBufferEdit == nil)
    }

    /// Each queued edit must advance the id, or the editor's
    /// apply-once guard swallows the second one.
    @Test func eachQueuedEditGetsAFreshID() throws {
        let (controller, file, dir) = try fixture(disk: "abc\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.openFile(file)
        controller.replaceInOpenBuffer(
            url: file, range: NSRange(location: 0, length: 0),
            with: "1", actionName: "Accept Completion")
        let first = try #require(controller.pendingBufferEdit).id
        controller.replaceInOpenBuffer(
            url: file, range: NSRange(location: 0, length: 0),
            with: "2", actionName: "Accept Completion")
        let second = try #require(controller.pendingBufferEdit).id
        #expect(second > first)
    }

    /// The co-pilot's match-based path still works alongside the
    /// ranged one.
    @Test func theMatchBasedCoPilotPathStillQueuesAnEdit() throws {
        let (controller, file, dir) = try fixture(disk: "Log \"old\" to the <console>.\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.openFile(file)
        #expect(controller.applyAIEditToOpenBuffer(
            url: file, oldString: "\"old\"", newString: "\"new\"") == true)
        let edit = try #require(controller.pendingBufferEdit)
        #expect(edit.range == nil)
        #expect(edit.oldString == "\"old\"")
        #expect(edit.actionName == "AI Edit")
    }

    /// Ambiguous matches are still refused (the co-pilot's
    /// exact-unique-match rule).
    @Test func anAmbiguousMatchIsRefused() throws {
        let (controller, file, dir) = try fixture(disk: "a\na\n")
        defer { try? FileManager.default.removeItem(at: dir) }

        controller.openFile(file)
        #expect(controller.applyAIEditToOpenBuffer(
            url: file, oldString: "a", newString: "b") == false)
    }
}
