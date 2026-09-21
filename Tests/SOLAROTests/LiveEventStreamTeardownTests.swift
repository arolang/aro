// ============================================================
// LiveEventStreamTeardownTests.swift
// SOLARO — the tail tears down on its own queue (GitLab #761)
// ============================================================
//
// deinit used to cancel the DispatchSource directly, from whatever
// thread released the last reference, while its own comment acknowledged
// that cancellation belongs on the owning queue. With a drain in flight
// that touched queue-owned state concurrently and closed the file handle
// under the read.

import Testing
import Foundation
@testable import SOLARO

@Suite("Live event stream teardown")
struct LiveEventStreamTeardownTests {

    private func temporaryFile() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("solaro-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        return root.appendingPathComponent("events.jsonl")
    }

    private func pauseLine(line: Int) -> String {
        #"{"t":1.0,"k":"pause","file":"main.aro","line":"\#(line)"}"# + "\n"
    }

    @Test func recordsAppendedAfterStartAreDelivered() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at:
            url.deletingLastPathComponent()) }

        let received = Received()
        let stream = LiveEventStream(url: url) { records in
            received.add(records.count)
        }
        stream.start()
        try await Task.sleep(for: .milliseconds(200))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(pauseLine(line: 3).utf8))
        try handle.close()

        for _ in 0..<50 where received.total == 0 {
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(received.total > 0)
        stream.stop()
    }

    @Test func stoppingTwiceIsFine() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at:
            url.deletingLastPathComponent()) }

        let stream = LiveEventStream(url: url) { _ in }
        stream.start()
        try await Task.sleep(for: .milliseconds(100))
        stream.stop()
        stream.stop()
        // Teardown is idempotent, so the termination handler and an
        // explicit stop can both run without fighting.
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func releasingWhileTailingDoesNotCrash() async throws {
        let url = try temporaryFile()
        defer { try? FileManager.default.removeItem(at:
            url.deletingLastPathComponent()) }

        // `start()` creates the file on its own queue; make it exist up
        // front so the writes below do not race that.
        FileManager.default.createFile(atPath: url.path, contents: nil)

        // Drop the stream without stopping it, while the file is being
        // written — the shape that used to cancel from the wrong queue.
        for _ in 0..<20 {
            let stream = LiveEventStream(url: url) { _ in }
            stream.start()
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(pauseLine(line: 1).utf8))
            try handle.close()
        }
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Counter shared between the delivery callback and the test.
    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
