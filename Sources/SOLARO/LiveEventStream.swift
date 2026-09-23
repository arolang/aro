// ============================================================
// LiveEventStream.swift
// SOLARO — tail .solaro/events.jsonl while the runtime runs
// ============================================================
//
// `aro run --record` and `aro debug --record` both append one JSON
// record per line to `.solaro/events.jsonl`. This watcher opens the
// file when the process starts, registers a DispatchSource against
// its file descriptor, and decodes each newly-appended line as it
// arrives so the canvas can light up nodes / push live values
// without waiting for the run to finish.
//
// Owned by `ConsoleProcess` — one stream per recording session.

import Foundation

/// Tails a JSONL file appendings live, decoding each new line via
/// `TimeTravelReader` and delivering each batch on the main queue.
///
/// The class is intentionally **not** `@MainActor`-isolated. The
/// DispatchSource callbacks fire on a utility queue, and capturing
/// a `@MainActor`-isolated class via `[weak self]` from those
/// callbacks triggers Swift Concurrency's runtime isolation
/// assertion on entry — even when the work is then dispatched to
/// main. By keeping the class nonisolated, the dispatch callbacks
/// can touch its internal state directly under a queue serial, and
/// only the user-visible callback hops to main.
final class LiveEventStream: @unchecked Sendable {

    /// Closure run for every batch of new records, delivered on the
    /// main queue. Receiving records in batches (vs. one at a time)
    /// lets ConsoleProcess apply them all under a single observation
    /// frame — a burst of 100 events from a hot loop produces one
    /// SwiftUI redraw instead of 100.
    let onRecords: ([TimeTravelRecord]) -> Void

    private let url: URL
    /// Serial queue that owns everything in `Watch`, so the
    /// DispatchSource callbacks and `stop()` can mutate it without
    /// racing.
    private let queue = DispatchQueue(label: "com.arolang.solaro.LiveEventStream")

    /// The queue-owned half of the stream (#761).
    ///
    /// Separated out so teardown can outlive the stream object. `deinit`
    /// used to call `source?.cancel()` directly, from whatever thread
    /// released the last reference — while acknowledging in its own
    /// comment that cancellation belongs on the owning queue. If a
    /// `drain()` was in flight, that touched queue-owned state
    /// concurrently and the cancel handler closed the file handle out
    /// from under the read. `ConsoleProcess` nils the stream from the
    /// main actor in its termination handler, so the window was real.
    ///
    /// Holding this in a box means `deinit` can hand the reference to
    /// the queue and let the teardown run serialised behind whatever is
    /// already in flight, without capturing a half-destroyed `self`.
    private final class Watch: @unchecked Sendable {
        var fileHandle: FileHandle?
        var source: DispatchSourceFileSystemObject?
        /// Bytes left over from the last read that didn't end on `\n` —
        /// prepended to the next chunk so we don't drop or corrupt
        /// records that arrive across read boundaries.
        var carry: Data = Data()

        /// Cancel the source. Idempotent, and only ever called on the
        /// owning queue. The cancel handler closes the handle.
        func teardown() {
            source?.cancel()
            source = nil
        }
    }

    private let watch = Watch()

    init(url: URL, onRecords: @escaping ([TimeTravelRecord]) -> Void) {
        self.url = url
        self.onRecords = onRecords
    }

    deinit {
        // Hand the box to the queue and let it do the work there. `self`
        // is not captured — only the box, which the closure keeps alive
        // exactly as long as it needs to (#761).
        let watch = self.watch
        queue.async { watch.teardown() }
    }

    /// Open the file (creating an empty one if missing so we can
    /// watch the parent directory immediately) and start the watch.
    /// Safe to call repeatedly — subsequent calls are no-ops.
    func start() {
        queue.async { [watch, url, queue] in
            guard watch.source == nil else { return }
            let fm = FileManager.default
            let dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            watch.fileHandle = handle
            // Skip whatever's already in the file — we want a clean
            // live feed of *this* session, not a replay of the last.
            let _ = try? handle.seekToEnd()

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: handle.fileDescriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: queue
            )
            // The event handler still needs the stream, for `onRecords`.
            // Weakly: a released stream has nobody to deliver to, and
            // the teardown its `deinit` queued is right behind this.
            src.setEventHandler { [weak self] in
                self?.drain()
            }
            // The cancel handler needs only the box, so it stays correct
            // after the stream is gone (#761).
            src.setCancelHandler {
                try? watch.fileHandle?.close()
                watch.fileHandle = nil
            }
            src.resume()
            watch.source = src
        }
    }

    /// Cancel the watch. Safe to call from any thread and safe to call
    /// twice; the actual teardown runs on the internal queue.
    func stop() {
        queue.async { [watch] in watch.teardown() }
    }

    /// Read whatever's available from the file handle, split it into
    /// complete JSONL records, and dispatch them as a single batch.
    /// Called on the internal queue; the user callback is hopped to
    /// main before invocation.
    private func drain() {
        guard let handle = watch.fileHandle else { return }
        let chunk: Data
        do {
            chunk = try handle.readToEnd() ?? Data()
        } catch {
            return
        }
        guard !chunk.isEmpty else { return }
        var buffer = watch.carry
        buffer.append(chunk)
        watch.carry = Data()
        // Split on \n; if the last segment doesn't end with \n, keep
        // it as carry for the next drain.
        var batch: [TimeTravelRecord] = []
        var lo = buffer.startIndex
        while let nl = buffer[lo..<buffer.endIndex].firstIndex(of: 0x0A) {
            let line = buffer[lo..<nl]
            if !line.isEmpty,
               let text = String(data: line, encoding: .utf8),
               let record = TimeTravelReader.parse(text).first
            {
                batch.append(record)
            }
            lo = buffer.index(after: nl)
        }
        if lo < buffer.endIndex {
            watch.carry = buffer[lo..<buffer.endIndex]
        }
        guard !batch.isEmpty else { return }
        let callback = onRecords
        DispatchQueue.main.async {
            callback(batch)
        }
    }
}
