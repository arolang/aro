// ============================================================
// FileWatchChangeTests.swift
// ARO Runtime — the compiled watcher reports what the interpreter reports
// GitLab #693
// ============================================================
//
// Three backends answer "what happened to this file?" from three unrelated
// sources, and before #693 two of them did not answer at all: inotify and the
// polling fallback printed a line and published nothing, so a `File Event
// Handler` in a Linux binary was registered and then never called.
//
// The third, FSEvents, published — but resolved its flags by asking whether
// the file exists *now*. FSEvents reports the flags accumulated for a path, so
// a file that is created and then written arrives with `ItemCreated` and
// `ItemModified` set together; "does it exist?" answers yes, and every
// creation was announced as a modification.
//
// `WatchedPathLedger` is the state that makes the question answerable. These
// tests are about that classification, because it is the part with a decision
// in it — the publishing itself is a straight-line mirror of
// `AROFileSystemService.handleFileEvent`.

import Foundation
import Testing
@testable import ARORuntime

#if !os(Windows)

@Suite("Compiled file-watch classification (#693)")
struct FileWatchChangeTests {

    private func tempDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "aro-693-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test("A path never seen before is a creation, not a modification")
    func firstSightingIsACreation() {
        let ledger = WatchedPathLedger()
        // Both flags set and the file on disk: the shape the old code got
        // wrong every single time a file was created and then written.
        #expect(ledger.classify("/w/a.txt", exists: true, sawCreate: true) == [.created])
    }

    @Test("The same path again is a modification")
    func secondSightingIsAModification() {
        let ledger = WatchedPathLedger()
        _ = ledger.classify("/w/a.txt", exists: true, sawCreate: true)
        #expect(ledger.classify("/w/a.txt", exists: true, sawCreate: true) == [.modified])
    }

    @Test("A path that is gone is a deletion")
    func vanishedPathIsADeletion() {
        let ledger = WatchedPathLedger()
        _ = ledger.classify("/w/a.txt", exists: true, sawCreate: true)
        #expect(ledger.classify("/w/a.txt", exists: false, sawCreate: false) == [.deleted])
    }

    @Test("A file created and deleted inside one coalescing window reports both")
    func shortLivedFileReportsBothHalves() {
        // FSEvents can hand over one event for a path whose whole life fell
        // inside the stream's latency. Reporting only the deletion would lose
        // the creation entirely; reporting nothing would lose both.
        let ledger = WatchedPathLedger()
        #expect(ledger.classify("/w/tmp.txt", exists: false, sawCreate: true) == [.created, .deleted])
    }

    @Test("A path that was never there and never created is not reported")
    func unknownAbsentPathIsSilent() {
        let ledger = WatchedPathLedger()
        #expect(ledger.classify("/w/ghost.txt", exists: false, sawCreate: false).isEmpty)
    }

    @Test("Deleting re-arms the path, so re-creating it is a creation again")
    func deletionForgetsThePath() {
        let ledger = WatchedPathLedger()
        _ = ledger.classify("/w/a.txt", exists: true, sawCreate: true)
        _ = ledger.classify("/w/a.txt", exists: false, sawCreate: false)
        #expect(ledger.classify("/w/a.txt", exists: true, sawCreate: true) == [.created])
    }

    @Test("Seeding means the first edit of a pre-existing file is a modification")
    func seedingPreventsSpuriousCreations() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/already-here.txt"
        try "content".write(toFile: file, atomically: true, encoding: .utf8)

        let ledger = WatchedPathLedger()
        ledger.seed(directory: dir)

        // Without the seed this would be `.created`, and a watcher started on
        // a populated directory would announce every existing file as new the
        // moment anyone touched it.
        #expect(ledger.classify(file, exists: true, sawCreate: false) == [.modified])
    }

    @Test("Seeding reaches files in subdirectories")
    func seedingIsRecursive() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sub = dir + "/nested"
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let file = sub + "/deep.txt"
        try "content".write(toFile: file, atomically: true, encoding: .utf8)

        let ledger = WatchedPathLedger()
        ledger.seed(directory: dir)

        // FSEvents watches a tree, so the ledger has to cover the tree.
        #expect(ledger.classify(file, exists: true, sawCreate: false) == [.modified])
    }

    @Test("Seeding a directory that is not there leaves an empty ledger")
    func seedingAMissingDirectoryIsSafe() {
        let ledger = WatchedPathLedger()
        ledger.seed(directory: "/no/such/directory")
        #expect(ledger.classify("/no/such/directory/x", exists: true, sawCreate: true) == [.created])
    }

    @Test("The three changes name the domain events compiled handlers subscribe to")
    func domainEventTypesMatchTheRegistrations() {
        // `LLVMCodeGenerator` registers a File Event Handler against exactly
        // these strings, and `AROFileSystemService` publishes exactly these
        // from the interpreter. A rename on either side silently unhooks
        // every compiled file handler, so it is worth asserting.
        #expect(FileWatchChange.created.domainEventType == "file.created")
        #expect(FileWatchChange.modified.domainEventType == "file.modified")
        #expect(FileWatchChange.deleted.domainEventType == "file.deleted")
    }
}

#endif
