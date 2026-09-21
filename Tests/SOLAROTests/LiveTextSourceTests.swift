// ============================================================
// LiveTextSourceTests.swift
// SOLARO — edits compute from the buffer, not the file (GitLab #754)
// ============================================================
//
// Canvas and inspector edits used to start from `String(contentsOf: url)`,
// compute a replacement and write the whole result back. Disk and buffer
// normally agree because of the autosave, so this was latent — until a
// write was refused. With the conflict bar up, a failed save, or the
// large-file write-back guard, the buffer holds work the file does not,
// and an edit computed from the file resurrects the stale text and
// persists it over the user's.
//
// `liveText(for:)` is the single accessor that answers this correctly:
// the editor buffer when there is one, then a debounced write still in
// flight, then the file.

import Testing
import Foundation
@testable import SOLARO

@Suite("Live text source", .serialized)
@MainActor
struct LiveTextSourceTests {

    private func temporaryProject() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-livetext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root
    }

    @Test func fallsBackToTheFileWhenNothingIsOpen() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)

        let controller = WorkspaceController(project: Project(rootPath: root))
        #expect(controller.liveText(for: file) == "on disk")
    }

    @Test func theEditorBufferWinsOverTheFile() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)

        let controller = WorkspaceController(project: Project(rootPath: root))
        controller.liveEditorText[file.standardizedFileURL] = "in the editor"
        // This is the whole bug: an edit computed from the file would
        // discard "in the editor" and write "on disk" back over it.
        #expect(controller.liveText(for: file) == "in the editor")
    }

    @Test func aDebouncedWriteStillInFlightWinsOverTheFile() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.aro")
        try "on disk".write(to: file, atomically: true, encoding: .utf8)

        let controller = WorkspaceController(project: Project(rootPath: root))
        controller.autosave("just typed", to: file)
        #expect(controller.liveText(for: file) == "just typed")
        // And once it lands, the file agrees.
        EditorWriteQueue.shared.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == "just typed")
    }

    @Test func aMissingFileWithNoBufferHasNoText() throws {
        let root = try temporaryProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = WorkspaceController(project: Project(rootPath: root))
        #expect(controller.liveText(for: root.appendingPathComponent("gone.aro"))
                    == nil)
    }
}
