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
/// `TimeTravelReader` and delivering the resulting record on the
/// main actor.
@MainActor
final class LiveEventStream {

    /// Closure run for every new record. Always called on the main
    /// actor — safe to mutate `@Observable` state from the callback.
    let onRecord: (TimeTravelRecord) -> Void

    private let url: URL
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    /// Bytes left over from the last read that didn't end on `\n` —
    /// prepended to the next chunk so we don't drop or corrupt
    /// records that arrive across read boundaries.
    private var carry: Data = Data()

    init(url: URL, onRecord: @escaping (TimeTravelRecord) -> Void) {
        self.url = url
        self.onRecord = onRecord
    }

    deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    /// Open the file (creating an empty one if missing so we can
    /// watch the parent directory immediately) and start the watch.
    /// Safe to call repeatedly — subsequent calls are no-ops.
    func start() {
        guard source == nil else { return }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        fileHandle = handle
        // Drain anything that's already in the file (a previous run
        // may have left records; we want a clean live feed of *this*
        // session). The caller relies on us calling `onRecord` only
        // for fresh appends.
        let _ = try? handle.seekToEnd()

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.drain() }
        }
        src.setCancelHandler { [weak self] in
            Task { @MainActor in
                try? self?.fileHandle?.close()
                self?.fileHandle = nil
            }
        }
        src.resume()
        source = src
    }

    /// Cancel the watch. Records that arrive after this point are
    /// ignored.
    func stop() {
        source?.cancel()
        source = nil
    }

    /// Read whatever's available from the file handle, split it into
    /// complete JSONL records, and dispatch each one.
    private func drain() {
        guard let handle = fileHandle else { return }
        let chunk: Data
        do {
            chunk = try handle.readToEnd() ?? Data()
        } catch {
            return
        }
        guard !chunk.isEmpty else { return }
        var buffer = carry
        buffer.append(chunk)
        carry = Data()
        // Split on \n; if the last segment doesn't end with \n, keep
        // it as carry for the next drain.
        var lo = buffer.startIndex
        while let nl = buffer[lo..<buffer.endIndex].firstIndex(of: 0x0A) {
            let line = buffer[lo..<nl]
            if !line.isEmpty,
               let text = String(data: line, encoding: .utf8),
               let record = TimeTravelReader.parse(text).first
            {
                onRecord(record)
            }
            lo = buffer.index(after: nl)
        }
        if lo < buffer.endIndex {
            carry = buffer[lo..<buffer.endIndex]
        }
    }
}
