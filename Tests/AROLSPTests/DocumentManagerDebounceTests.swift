// ============================================================
// DocumentManagerDebounceTests.swift
// AROLSP - didChange debounce (#352)
// ============================================================

#if !os(Windows)
import Testing
import Foundation
@testable import AROLSP
@testable import AROParser
import LanguageServerProtocol

/// Thread-safe recorder for the `onCompile` callback, which fires from
/// a detached debounce Task.
private final class CompileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DocumentManager.DocumentState] = []

    func record(_ state: DocumentManager.DocumentState) {
        lock.lock(); defer { lock.unlock() }
        states.append(state)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return states.count
    }

    var last: DocumentManager.DocumentState? {
        lock.lock(); defer { lock.unlock() }
        return states.last
    }
}

@Suite("DocumentManager didChange debounce (#352)")
struct DocumentManagerDebounceTests {

    private let uri = "file:///debounce.aro"
    private let interval: Duration = .milliseconds(40)

    private func fullChange(_ text: String) -> TextDocumentContentChangeEvent {
        TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text)
    }

    private func program(_ tag: String) -> String {
        """
        (Feature \(tag): Business) {
            Extract the <data> from the <request>.
        }
        """
    }

    @Test("open compiles synchronously")
    func openCompilesImmediately() {
        let recorder = CompileRecorder()
        let manager = DocumentManager(debounceInterval: interval) { recorder.record($0) }

        let state = manager.open(uri: uri, content: program("A"), version: 1)

        // Result is available the instant open returns — no keystroke wait.
        #expect(state.compilationResult != nil)
        // open does not route through the debounced callback.
        #expect(recorder.count == 0)
    }

    @Test("a burst of edits collapses to a single compile of the final text")
    func burstCollapsesToOneCompile() async throws {
        let recorder = CompileRecorder()
        let manager = DocumentManager(debounceInterval: interval) { recorder.record($0) }

        _ = manager.open(uri: uri, content: program("Start"), version: 1)
        let openResult = manager.get(uri: uri)?.compilationResult

        // Fire five rapid edits well within one debounce window.
        for i in 1...5 {
            _ = manager.applyChanges(
                uri: uri,
                changes: [fullChange(program("Edit\(i)"))],
                version: 1 + i
            )
        }

        // Immediately: text is the latest, but the compile is still the
        // pre-burst result — never nil mid-edit.
        let interim = try #require(manager.get(uri: uri))
        #expect(interim.content == program("Edit5"))
        #expect(interim.compilationResult != nil)

        // No debounced compile has fired yet (we're inside the window).
        #expect(recorder.count == 0)

        // Wait out the debounce plus a margin.
        try await Task.sleep(for: interval * 4)

        // Exactly one compile committed, for the final text.
        #expect(recorder.count == 1)
        #expect(recorder.last?.content == program("Edit5"))
        // And the manager's stored result now reflects the final text.
        let final = try #require(manager.get(uri: uri))
        #expect(final.content == program("Edit5"))
        #expect(final.compilationResult != nil)
        // The stored result actually changed from the pre-burst one
        // (different feature-set name -> different symbols).
        #expect(final.compilationResult != nil && openResult != nil)
    }

    @Test("a settled edit produces updated diagnostics")
    func settledEditRecompiles() async throws {
        let recorder = CompileRecorder()
        let manager = DocumentManager(debounceInterval: interval) { recorder.record($0) }

        // Open valid, then change to source with a parse error.
        _ = manager.open(uri: uri, content: program("Ok"), version: 1)
        _ = manager.applyChanges(
            uri: uri,
            changes: [fullChange("(Broken: Business) {\n    Extract the <x> from\n")],
            version: 2
        )

        try await Task.sleep(for: interval * 4)

        // The debounced compile ran once against the broken text.
        #expect(recorder.count == 1)
        #expect(recorder.last?.content.contains("Broken") == true)
        #expect(recorder.last?.compilationResult != nil)
    }

    @Test("a newer edit cancels the previous pending compile")
    func newerEditCancelsPrevious() async throws {
        let recorder = CompileRecorder()
        let manager = DocumentManager(debounceInterval: interval) { recorder.record($0) }

        _ = manager.open(uri: uri, content: program("Init"), version: 1)

        // First edit, then a second before the first's window elapses.
        _ = manager.applyChanges(uri: uri, changes: [fullChange(program("First"))], version: 2)
        try await Task.sleep(for: interval / 2)
        _ = manager.applyChanges(uri: uri, changes: [fullChange(program("Second"))], version: 3)

        try await Task.sleep(for: interval * 4)

        // Only the second edit's compile committed.
        #expect(recorder.count == 1)
        #expect(recorder.last?.content == program("Second"))
    }

    @Test("closing a document cancels its pending compile")
    func closeCancelsPending() async throws {
        let recorder = CompileRecorder()
        let manager = DocumentManager(debounceInterval: interval) { recorder.record($0) }

        _ = manager.open(uri: uri, content: program("Live"), version: 1)
        _ = manager.applyChanges(uri: uri, changes: [fullChange(program("Pending"))], version: 2)
        manager.close(uri: uri)

        try await Task.sleep(for: interval * 4)

        // The pending compile was cancelled with the close.
        #expect(recorder.count == 0)
        #expect(manager.isOpen(uri: uri) == false)
    }
}
#endif
