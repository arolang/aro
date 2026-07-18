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
    // Kept short so tests are quick, but not so short that the
    // "not yet fired" window is racy on a loaded CI runner.
    private let interval: Duration = .milliseconds(60)

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

    /// Poll `condition` until it holds or `timeout` elapses. Used instead
    /// of a fixed sleep so the tests stay green on slow CI where the
    /// debounced compile takes longer than a couple of debounce
    /// intervals to land. Returns as soon as the condition is met.
    private func waitUntil(
        _ timeout: Duration = .seconds(10),
        _ condition: @Sendable () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
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

        // Wait for the debounced compile to land (poll, don't guess).
        await waitUntil { recorder.count >= 1 }

        // Exactly one compile committed, for the final text.
        #expect(recorder.count == 1)
        #expect(recorder.last?.content == program("Edit5"))
        // And the manager's stored result now reflects the final text.
        let final = try #require(manager.get(uri: uri))
        #expect(final.content == program("Edit5"))
        #expect(final.compilationResult != nil)
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

        await waitUntil { recorder.count >= 1 }

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

        await waitUntil { recorder.count >= 1 }

        // Only the second edit's compile committed — the first was
        // cancelled before its window elapsed, so it never fired.
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

        // A cancelled task never fires regardless of timing; give it well
        // over the debounce window to prove nothing lands.
        try await Task.sleep(for: interval * 8)

        #expect(recorder.count == 0)
        #expect(manager.isOpen(uri: uri) == false)
    }
}
#endif
