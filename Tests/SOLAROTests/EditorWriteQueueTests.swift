// ============================================================
// EditorWriteQueueTests.swift
// SOLARO — debounced editor writes (GitLab #748)
// ============================================================
//
// The queue is a MainActor singleton, so every test runs serialised on the
// main actor and clears what it queued. Each test uses its own URL, which is
// the queue's key, so nothing leaks between them.

import Testing
import Foundation
@testable import SOLARO

@Suite("Editor write queue", .serialized)
@MainActor
struct EditorWriteQueueTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/solaro-write-queue/\(name).aro")
    }

    /// A queue of this suite's own.
    ///
    /// The app's queue is a singleton that anything can flush — another
    /// suite's controller autosave, a graph-diff load — so a timing
    /// assertion against it is a race the test loses (#748).
    private func makeQueue() -> EditorWriteQueue {
        EditorWriteQueue(installsLifecycleFlush: false)
    }

    @Test func holdsTheTextUntilFlushed() {
        let queue = makeQueue()
        let file = url("holds")
        var written: [String] = []
        queue.enqueue("one", to: file) { text, _ in
            written.append(text); return true
        }
        // Nothing has reached the writer yet — that is the whole point.
        #expect(written.isEmpty)
        #expect(queue.pendingText(for: file) == "one")

        queue.flush()
        #expect(written == ["one"])
        #expect(queue.pendingText(for: file) == nil)
    }

    @Test func aBurstCollapsesToOneWrite() {
        let queue = makeQueue()
        let file = url("burst")
        var written: [String] = []
        for character in ["L", "Lo", "Log"] {
            queue.enqueue(character, to: file) { text, _ in
                written.append(text); return true
            }
        }
        queue.flush()
        // Three keystrokes, one write, and it carries the latest text.
        #expect(written == ["Log"])
    }

    @Test func separateFilesEachGetTheirOwnWrite() {
        let queue = makeQueue()
        let first = url("first")
        let second = url("second")
        var written: [URL: String] = [:]
        queue.enqueue("a", to: first) { text, url in
            written[url] = text; return true
        }
        queue.enqueue("b", to: second) { text, url in
            written[url] = text; return true
        }
        #expect(queue.flush() == 2)
        #expect(written[first.standardizedFileURL] == "a")
        #expect(written[second.standardizedFileURL] == "b")
    }

    @Test func cancelDropsTheQueuedWrite() {
        let queue = makeQueue()
        let file = url("cancelled")
        var written = 0
        queue.enqueue("draft", to: file) { _, _ in
            written += 1; return true
        }
        queue.cancel(file)
        #expect(queue.pendingText(for: file) == nil)
        queue.flush()
        // An explicit save has already written the formatted text; the
        // debounced copy must not land behind it and undo the formatting.
        #expect(written == 0)
    }

    @Test func flushingAnEmptyQueueIsFree() {
        let queue = makeQueue()
        #expect(!queue.hasPendingWrites)
        #expect(queue.flush() == 0)
    }

    @Test func theTimerWritesWithoutAnExplicitFlush() async throws {
        let queue = makeQueue()
        let file = url("debounced")
        var written: [String] = []
        queue.enqueue("typed", to: file) { text, _ in
            written.append(text); return true
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(written.isEmpty)          // still inside the quiet period
        try await Task.sleep(for: .milliseconds(400))
        #expect(written == ["typed"])     // the debounce fired on its own
    }

    @Test func continuousTypingStillReachesDiskAtTheCeiling() async throws {
        let queue = makeQueue()
        let file = url("ceiling")
        var written: [String] = []
        let deadline = ContinuousClock.now + .milliseconds(2600)
        var keystroke = 0
        while ContinuousClock.now < deadline, written.isEmpty {
            keystroke += 1
            queue.enqueue("x\(keystroke)", to: file) { text, _ in
                written.append(text); return true
            }
            // Faster than the 300 ms debounce, so the timer never fires:
            // only the maximum-delay ceiling can save this file.
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(written.count == 1)
        queue.flush()
    }
}
