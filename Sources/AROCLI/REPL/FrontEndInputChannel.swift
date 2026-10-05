// ============================================================
// FrontEndInputChannel.swift
// ARO REPL — asking the front-end a question (GitLab #690)
// ============================================================
//
// `Prompt`, `Select` and `Ask` need an answerer (ARO-0083 §5.2–5.3).
// Under `aro run` and `aro repl` that is the terminal. Behind a pipe —
// `aro repl --json`, `aro kernel`, SOLARO — there is no terminal, and the
// answerer is the front-end itself: Jupyter's `input_request` on the
// stdin channel, or the symmetric `input_request` message of ARO's JSON
// protocol.
//
// Two pieces live here, both shared by the two servers so neither can
// drift from the other:
//
//   * `FrontEndInputChannel` — the `InteractiveInputService` a server
//     registers on its session. A box around one closure, holding the
//     server weakly, so a session cannot keep its server alive and a
//     question asked after the server went away fails rather than hangs.
//   * `StdinLineReader` — one thread reading stdin into a queue, which is
//     what makes a *timed* read possible without abandoning a blocking
//     `readLine` that would then swallow somebody else's line.

import Foundation
import ARORuntime

/// The front-end as an answerer of interactive questions.
final class FrontEndInputChannel: InteractiveInputService, @unchecked Sendable {

    /// (prompt, hidden) → the user's answer. Throws
    /// `InteractiveInputError` when no answer is coming.
    typealias Ask = @Sendable (String, Bool) async throws -> String

    private let ask: Ask

    init(ask: @escaping Ask) {
        self.ask = ask
    }

    func requestLine(prompt: String, hidden: Bool) async throws -> String {
        try await ask(prompt, hidden)
    }

    // `requestChoice` is inherited from the protocol extension: it
    // renders the numbered menu and asks for a number, which is exactly
    // what the terminal does. A front-end with a real picker would
    // override it; neither of ours has one yet.
}

/// Reads stdin on one dedicated thread, into a queue two consumers share.
///
/// The JSON server has two readers of the same descriptor: its request
/// loop, and an open `input_request` waiting for a reply. Having each
/// call `readLine` directly worked only by accident — the request loop
/// happens to be parked inside `handle(_:)` while a cell runs — and it
/// made a *bounded* wait impossible: abandoning a blocking `readLine` on
/// timeout leaves a thread that will consume the next line and hand it to
/// nobody.
///
/// One thread, one queue, and a timeout becomes a queue poll that leaves
/// the line where it is (GitLab #690).
final class StdinLineReader: @unchecked Sendable {

    enum Next: Equatable {
        case line(String)
        /// stdin reached EOF — the client is gone, and no further line
        /// will ever arrive.
        case endOfInput
        /// Nothing within the deadline. The line, if it ever comes, is
        /// still queued for the next reader.
        case timedOut
    }

    private let condition = NSCondition()
    private var pending: [String] = []
    private var atEnd = false
    private var started = false

    /// Start the reader thread. Idempotent.
    func start() {
        condition.lock()
        guard !started else {
            condition.unlock()
            return
        }
        started = true
        condition.unlock()

        let thread = Thread { [self] in
            readDescriptorIntoQueue()
            condition.lock()
            atEnd = true
            condition.broadcast()
            condition.unlock()
        }
        thread.name = "aro.repl.stdin"
        thread.start()
    }

    /// Split fd 0 into lines with `read(2)`, deliberately **not** through
    /// `readLine`.
    ///
    /// `readLine` goes through stdio, so it takes `stdin`'s `FILE` lock and
    /// then sits in `read()` holding it until a line arrives. This thread
    /// exists to wait indefinitely, so it would hold that lock essentially
    /// forever — and `OutputCapture.drain` ends every cell with `fflush(nil)`,
    /// which `_fwalk`s *every* stream, `stdin` included, and blocks on exactly
    /// that lock.
    ///
    /// The result was a deadlock with no bad line of its own: a cell's result
    /// was never sent, the next request was never read, and the session
    /// unjammed only when the front-end closed stdin — so `aro repl --json`
    /// hung behind a pipe that stayed open, which is every notebook
    /// (`integration:jupyter` ran into its 3h ceiling instead of ~210s).
    ///
    /// `fflush(nil)` is not the thing to change: it is deliberate, because
    /// naming `stdout` on Linux touches a mutable Glibc global. Reading the
    /// descriptor directly takes no stdio lock at all, so neither side can
    /// wait on the other.
    private func readDescriptorIntoQueue() {
        var carry: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)

        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(0, raw.baseAddress, raw.count)
            }
            if count == 0 { break }                       // EOF
            if count < 0 {
                if errno == EINTR { continue }            // a signal, not an end
                break
            }

            var lines: [String] = []
            for byte in buffer[0..<count] {
                if byte == UInt8(ascii: "\n") {
                    // A line may be framed CRLF by a Windows front-end.
                    if carry.last == UInt8(ascii: "\r") { carry.removeLast() }
                    lines.append(String(decoding: carry, as: UTF8.self))
                    carry.removeAll(keepingCapacity: true)
                } else {
                    carry.append(byte)
                }
            }
            guard !lines.isEmpty else { continue }

            condition.lock()
            pending.append(contentsOf: lines)
            condition.signal()
            condition.unlock()
        }

        // A final line with no newline is still a line the client sent.
        guard !carry.isEmpty else { return }
        condition.lock()
        pending.append(String(decoding: carry, as: UTF8.self))
        condition.signal()
        condition.unlock()
    }

    /// Put a line back at the head of the queue.
    ///
    /// For the one message an open `input_request` must not swallow:
    /// `shutdown`. It is a legitimate way out of a question — the
    /// front-end is closing the session — and the statement fails on it,
    /// but the request loop still has to see it and exit, or the server
    /// would sit on a closed front-end's stdin (GitLab #690).
    func unread(_ line: String) {
        condition.lock()
        pending.insert(line, at: 0)
        condition.signal()
        condition.unlock()
    }

    /// Take the next line, waiting at most `timeoutSeconds` (nil waits
    /// until a line or EOF). Blocks the calling thread — callers on an
    /// async path must hop to a `DispatchQueue` first.
    func next(timeoutSeconds: Double?) -> Next {
        condition.lock()
        defer { condition.unlock() }

        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        while pending.isEmpty && !atEnd {
            if let deadline {
                if !condition.wait(until: deadline) {
                    return .timedOut
                }
            } else {
                condition.wait()
            }
        }
        if !pending.isEmpty {
            return .line(pending.removeFirst())
        }
        return .endOfInput
    }

    /// `next` on a cooperative-pool-safe path: the blocking wait happens
    /// on a global queue thread, not on the executor the runtime needs.
    ///
    /// Spelled differently rather than overloaded on `async`: an
    /// overload pair would resolve by context, and the one that must
    /// never be picked by accident is the blocking one.
    func nextOffPool(timeoutSeconds: Double?) async -> Next {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.next(timeoutSeconds: timeoutSeconds))
            }
        }
    }
}
