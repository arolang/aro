// ============================================================
// OutputCapture.swift
// ARO REPL — capturing a file descriptor into stream messages
// ============================================================
//
// `aro repl --json` speaks its protocol on stdout, but ARO programs write to
// stdout too — `Log` goes there directly (ResponseActions), and so do a
// handful of warnings and `print`s scattered through the runtime. A single
// `Log` would corrupt the protocol stream and desynchronise the client.
//
// Rather than chase every writer, the descriptor itself is redirected: the
// real stdout is duplicated for protocol use, then fd 1 is replaced with a
// pipe this class drains. Anything anyone writes — Swift `print`, a
// FileHandle write, a C library, a crashing plugin — is captured and
// forwarded as a `stream` message. The same applies to fd 2.
//
// The other half of the job is ordering. A pipe has no flush semantics, so
// after a cell finishes the server must know that everything the cell wrote
// has been forwarded *before* it sends the result — otherwise a notebook
// shows output arriving after the value it produced. `drain` solves that by
// writing a sentinel into the pipe and waiting for the reader to reach it.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// POSIX only: `pipe`/`dup2` have no portable Windows equivalent here. On
// Windows the JSON REPL falls back to the `ConsoleObject` sink, which
// catches `Log` — the writer that matters — but not stray `print`s.
#if !os(Windows)

final class OutputCapture: @unchecked Sendable {

    /// Stream name reported to the client (`stdout` / `stderr`).
    let name: String

    private let targetFD: Int32
    private let readFD: Int32
    private let emit: @Sendable (String, String) -> Void

    private let lock = NSLock()
    private var buffer = Data()
    private var pendingMarker: Data?
    private let barrier = DispatchSemaphore(value: 0)

    /// The byte that begins a drain sentinel. U+0001 is not something an ARO
    /// program prints, and picking a single byte means the "might be a
    /// partial sentinel" check is a single scan.
    private static let sentinelByte: UInt8 = 0x01

    /// Redirect `targetFD` into a pipe and start draining it.
    ///
    /// Returns nil when the pipe cannot be created, in which case the caller
    /// runs without capture rather than failing to start — a REPL that
    /// prints in the wrong place still beats no REPL.
    init?(name: String, targetFD: Int32, emit: @escaping @Sendable (String, String) -> Void) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        guard dup2(fds[1], targetFD) >= 0 else {
            close(fds[0])
            close(fds[1])
            return nil
        }
        close(fds[1])

        self.name = name
        self.targetFD = targetFD
        self.readFD = fds[0]
        self.emit = emit

        let thread = Thread { [weak self] in self?.readLoop() }
        thread.name = "aro-capture-\(name)"
        // No explicit stackSize. 512 KB matches Darwin's default and so
        // read as harmless, but on Linux the default is 8 MB — setting it
        // shrank this thread's stack sixteenfold on one platform only.
        // The loop is not deep by itself, but `emit` runs on it and goes
        // through JSON encoding and a protocol write, and a stack overflow
        // there is a SIGSEGV with no message: precisely the silent death
        // the Jupyter kernel reported from Linux CI and could not
        // reproduce on macOS (GitLab #490).
        thread.start()
    }

    // MARK: - Reading

    private func readLoop() {
        let chunkSize = 8192
        var chunk = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let count = read(readFD, &chunk, chunkSize)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            if count == 0 { break }   // write end closed

            lock.lock()
            buffer.append(contentsOf: chunk[0..<count])
            let messages = extractLocked()
            lock.unlock()

            for text in messages {
                emit(name, text)
            }
        }
    }

    /// Pull everything safely emittable out of `buffer`.
    ///
    /// "Safely" means two things: never emit a partial drain sentinel (it
    /// would show up as garbage in a cell), and never emit a partial UTF-8
    /// sequence (it would not decode at all). Both are handled by holding the
    /// tail back until the next read completes it.
    ///
    /// Caller holds `lock`.
    private func extractLocked() -> [String] {
        var messages: [String] = []

        if let marker = pendingMarker, let range = buffer.range(of: marker) {
            let head = buffer[buffer.startIndex..<range.lowerBound]
            if !head.isEmpty {
                // Everything up to the sentinel is complete by definition —
                // the writer flushed before sending it — so decode lossily
                // rather than hold anything back for a continuation that is
                // never coming.
                messages.append(String(decoding: head, as: UTF8.self))
            }
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            pendingMarker = nil
            barrier.signal()
            return messages
        }

        // Hold back from the last sentinel byte: what follows it may be the
        // beginning of a sentinel whose remainder has not arrived yet.
        var end = buffer.endIndex
        if let sentinel = buffer.lastIndex(of: Self.sentinelByte) {
            end = sentinel
        }
        guard end > buffer.startIndex else { return messages }

        let slice = buffer[buffer.startIndex..<end]
        guard let (text, consumed) = decodeComplete(slice), consumed > 0 else { return messages }
        messages.append(text)
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed))
        return messages
    }

    /// Decode as much of `slice` as forms complete UTF-8, returning the text
    /// and how many bytes it consumed.
    ///
    /// A multi-byte character split across two reads would otherwise decode
    /// to nothing; the trailing bytes stay in the buffer and go out with the
    /// next chunk instead.
    private func decodeComplete(_ slice: Data) -> (String, Int)? {
        if slice.isEmpty { return nil }
        if let text = String(data: slice, encoding: .utf8) { return (text, slice.count) }

        for drop in 1...3 where slice.count > drop {
            let shorter = slice.prefix(slice.count - drop)
            if let text = String(data: shorter, encoding: .utf8) {
                return (text, shorter.count)
            }
        }
        return nil
    }

    // MARK: - Draining

    /// Flush everything written so far and wait until it has been emitted.
    ///
    /// Called between the end of a cell and its result message, so a client
    /// can rely on having seen all of a cell's output by the time the result
    /// arrives. The timeout is a safety valve: if a sentinel is somehow lost
    /// (a plugin closing fd 1, say), the REPL keeps answering instead of
    /// hanging forever on a semaphore.
    func drain(token: Int) {
        let marker = "\u{01}ARO-DRAIN-\(token)\u{01}"
        let bytes = Data(marker.utf8)

        lock.lock()
        pendingMarker = bytes
        lock.unlock()

        // Order matters: buffered FILE* content must reach the pipe before
        // the sentinel, or it would be emitted as part of the *next* cell.
        fflush(nil)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(targetFD, base.advanced(by: written), raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }

        if barrier.wait(timeout: .now() + .seconds(2)) == .timedOut {
            lock.lock()
            pendingMarker = nil
            lock.unlock()
        }
    }
}

#endif
