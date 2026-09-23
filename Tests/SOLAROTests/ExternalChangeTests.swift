// ============================================================
// ExternalChangeTests.swift
// SOLARO — external-file-change detection (GitLab #536)
// ============================================================

import Testing
import Foundation
@testable import SOLARO

@Suite("External change policy")
struct ExternalChangePolicyTests {

    /// Our own autosave coming back around the watcher.
    @Test func aDiskCopyMatchingTheBufferIsInSync() {
        #expect(ExternalChangePolicy.outcome(
            buffer: "same", lastSaved: "same", disk: "same") == .inSync)
    }

    /// The git-checkout case: everything the user typed is already
    /// saved, so the external write is the only difference.
    @Test func aCleanBufferTakesTheDiskVersion() {
        #expect(ExternalChangePolicy.outcome(
            buffer: "old", lastSaved: "old", disk: "new") == .reload)
    }

    /// The case that must never autosave: the buffer holds work that
    /// never reached disk AND disk moved on.
    @Test func aDirtyBufferConflicts() {
        #expect(ExternalChangePolicy.outcome(
            buffer: "mine", lastSaved: "old", disk: "theirs") == .conflict)
    }

    /// A failed save (GitLab #532) leaves buffer ≠ lastSaved, so an
    /// external write is a conflict rather than a silent reload that
    /// would throw the unsaved text away.
    @Test func aFailedSaveMakesTheNextExternalWriteAConflict() {
        #expect(ExternalChangePolicy.outcome(
            buffer: "typed but never written",
            lastSaved: "original",
            disk: "changed elsewhere") == .conflict)
    }

    @Test func noBaselineIsTreatedAsUnsaved() {
        #expect(ExternalChangePolicy.outcome(
            buffer: "mine", lastSaved: nil, disk: "theirs") == .conflict)
    }

    @Test func aFileWithNoOpenEditorJustReloads() {
        #expect(ExternalChangePolicy.outcome(
            buffer: nil, lastSaved: "old", disk: "new") == .reload)
    }
}

@Suite("External change handling", .serialized)
@MainActor
struct ExternalChangeHandlingTests {

    private func fixture() throws -> (WorkspaceController, URL, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("main.aro")
        try "Log \"before\" to the <console>.\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let controller = WorkspaceController(project: Project(rootPath: dir))
        return (controller, file, dir)
    }

    /// Opening a file establishes the baseline the policy needs.
    @Test func openingAFileRecordsItsDiskBaseline() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        #expect(controller.lastSavedText[file.standardizedFileURL]
                == "Log \"before\" to the <console>.\n")
    }

    /// Writing through the editor's save path moves the baseline, so
    /// the write doesn't look like somebody else's.
    @Test func savingMovesTheBaseline() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        controller.writeToDisk("Log \"after\" to the <console>.\n", to: file)
        #expect(controller.lastSavedText[file.standardizedFileURL]
                == "Log \"after\" to the <console>.\n")
    }

    /// End to end over `reloadFromDisk` (the File → Reload command,
    /// and what the branch picker now calls): a clean buffer adopts
    /// the checkout.
    @Test func reloadAdoptsTheNewCheckoutForACleanBuffer() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        // Somebody else rewrites the file (git checkout).
        try "Log \"from the other branch\" to the <console>.\n"
            .write(to: file, atomically: true, encoding: .utf8)

        controller.reloadFromDisk()
        #expect(controller.liveEditorText[file.standardizedFileURL]
                == "Log \"from the other branch\" to the <console>.\n")
        #expect(!controller.isConflicted(file))
    }

    /// The bug this issue is about: with unsaved work in the buffer,
    /// a checkout must NOT be silently overwritten — the file goes
    /// conflicted, which is what suspends autosave.
    @Test func reloadFlagsAConflictForADirtyBuffer() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        // Unsaved edit: buffer moved, baseline did not.
        controller.liveEditorText[file.standardizedFileURL] = "Log \"mine\".\n"
        try "Log \"theirs\".\n".write(to: file, atomically: true, encoding: .utf8)

        controller.reloadFromDisk()
        #expect(controller.isConflicted(file))
        // The user's text is still there — nothing was thrown away.
        #expect(controller.liveEditorText[file.standardizedFileURL]
                == "Log \"mine\".\n")
        // …and disk still holds the checkout, not the stale buffer.
        #expect(try String(contentsOf: file, encoding: .utf8) == "Log \"theirs\".\n")
    }

    @Test func reloadResolutionTakesTheDiskVersion() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        controller.liveEditorText[file.standardizedFileURL] = "Log \"mine\".\n"
        try "Log \"theirs\".\n".write(to: file, atomically: true, encoding: .utf8)
        controller.reloadFromDisk()

        controller.resolveConflictByReloading(file)
        #expect(!controller.isConflicted(file))
        #expect(controller.liveEditorText[file.standardizedFileURL]
                == "Log \"theirs\".\n")
    }

    @Test func keepMineWritesTheBufferAndClearsTheConflict() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        controller.liveEditorText[file.standardizedFileURL] = "Log \"mine\".\n"
        try "Log \"theirs\".\n".write(to: file, atomically: true, encoding: .utf8)
        controller.reloadFromDisk()

        controller.resolveConflictByKeepingBuffer(file)
        #expect(!controller.isConflicted(file))
        #expect(try String(contentsOf: file, encoding: .utf8) == "Log \"mine\".\n")
        // Baseline moved with the write, so the next external change
        // is judged against the right starting point.
        #expect(controller.lastSavedText[file.standardizedFileURL]
                == "Log \"mine\".\n")
    }

    @Test func closingATabClearsItsConflict() throws {
        let (controller, file, dir) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        controller.openFile(file)
        controller.liveEditorText[file.standardizedFileURL] = "Log \"mine\".\n"
        try "Log \"theirs\".\n".write(to: file, atomically: true, encoding: .utf8)
        controller.reloadFromDisk()
        #expect(controller.isConflicted(file))

        controller.closeTab(file)
        #expect(!controller.isConflicted(file))
    }
}

@Suite("External file watcher", .serialized)
@MainActor
struct ExternalFileWatcherTests {

    @Test func reportsAnExternalWrite() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.aro")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = ExternalFileWatcher(debounce: .milliseconds(20))
        var seen: [URL] = []
        watcher.onChange = { seen.append($0) }
        watcher.watch([file])
        #expect(watcher.watchedCount == 1)

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        // Poll rather than sleep 400ms and hope (GitLab #849). The subject is
        // that the watcher fires at all; how long kqueue and a 20ms debounce
        // take under full-suite load is not this test's business.
        let fired = await eventually { seen.contains(file.standardizedFileURL) }
        #expect(fired)
        watcher.stop()
        #expect(watcher.watchedCount == 0)
    }

    /// An atomic write replaces the inode, so the watcher has to
    /// re-arm on the path — otherwise it goes deaf after the first
    /// external change, which is precisely the `git checkout` case.
    @Test func keepsWatchingAcrossAnAtomicReplace() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.aro")
        try "one\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = ExternalFileWatcher(debounce: .milliseconds(20))
        var count = 0
        watcher.onChange = { _ in count += 1 }
        watcher.watch([file])

        try "two\n".write(to: file, atomically: true, encoding: .utf8)
        let sawFirst = await eventually { count >= 1 }
        #expect(sawFirst)
        let afterFirst = count

        // Wait for the re-arm, not for a clock (GitLab #849). An atomic write
        // is unlink+rename, so `reinstall` drops the entry and re-opens the
        // path a moment later; `watchedCount` going back to 1 is that moment,
        // observable rather than guessed at. The 400ms sleep this replaces was
        // only ever "long enough, probably" — and writing the second file
        // during the gap is a change the watcher genuinely cannot see.
        let rearmed = await eventually { watcher.watchedCount == 1 }
        #expect(rearmed)

        try "three\n".write(to: file, atomically: true, encoding: .utf8)
        // The point of the test: the *second* change arrives only because the
        // watcher re-armed on the path after the inode was replaced.
        let sawSecond = await eventually { count > afterFirst }
        #expect(sawSecond)
        watcher.stop()
    }

    @Test func rewatchingKeepsExistingEntriesAndDropsRemovedOnes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.aro")
        let b = dir.appendingPathComponent("b.aro")
        try "a\n".write(to: a, atomically: true, encoding: .utf8)
        try "b\n".write(to: b, atomically: true, encoding: .utf8)

        let watcher = ExternalFileWatcher(debounce: .milliseconds(20))
        watcher.watch([a, b])
        #expect(watcher.watchedCount == 2)
        watcher.watch([a])
        #expect(watcher.watchedCount == 1)
        watcher.stop()
    }
}
