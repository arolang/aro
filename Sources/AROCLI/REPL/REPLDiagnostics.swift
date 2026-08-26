// ============================================================
// REPLDiagnostics.swift
// ARO REPL — why the process died, when it hides its own stderr
// ============================================================
//
// `aro repl --json` redirects fd 1 *and fd 2* into pipes it drains
// itself, so program output arrives as protocol messages instead of
// corrupting the channel (see OutputCapture). The cost is that the
// server also swallows its own dying words: a crash writes to fd 2,
// fd 2 is the capture pipe, and the reader thread is gone or the
// process is already unwinding, so nothing reaches the client.
//
// That is exactly what the Jupyter kernel reported from CI:
//
//     The ARO REPL exited unexpectedly.
//
// with an empty detail. The kernel prints whatever the process wrote
// to stderr; the process had arranged for that to be nowhere.
//
// So the server keeps a duplicate of the *real* stderr before it
// redirects anything, and reports its own death on that descriptor.
// Two cases are worth reporting and they need different machinery:
//
//   * a fatal signal — SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP.
//     The handler must be async-signal-safe, so it may only `write`
//     a pre-rendered buffer to a raw descriptor. No allocation, no
//     Swift runtime calls, no String interpolation.
//
//   * a clean exit that nobody asked for. `run()` returns when stdin
//     reaches EOF, which from the client's side is indistinguishable
//     from a crash. `markShuttingDown()` records the one exit that is
//     expected; anything else says so on the way out.
//
// None of this makes the REPL more reliable. It makes the next
// failure legible, which is the part that was missing.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if !os(Windows)

enum REPLDiagnostics {

    /// A duplicate of stderr taken before `OutputCapture` replaces it.
    /// -1 until `install` runs, which is also the "not installed" guard
    /// the signal handler checks.
    nonisolated(unsafe) private static var diagnosticFD: Int32 = -1

    /// Set when the server is stopping on purpose, so the exit reporter
    /// stays quiet for the one exit that is not a surprise.
    nonisolated(unsafe) private static var shuttingDown = false

    /// Pre-rendered messages. Built once, at install time, because a
    /// signal handler cannot allocate.
    nonisolated(unsafe) private static var signalMessages: [Int32: [UInt8]] = [:]

    /// Save the real stderr and arm the reporters.
    ///
    /// Call before `OutputCapture` touches fd 2 — after that, the
    /// descriptor this needs is a pipe into the process's own reader
    /// thread, which is no use to anyone once the process is dying.
    static func install() {
        guard diagnosticFD < 0 else { return }
        diagnosticFD = dup(STDERR_FILENO)
        guard diagnosticFD >= 0 else { return }

        // A server that dies from SIGPIPE dies silently, and every other
        // long-lived stdio/socket server in this codebase already ignores
        // it (AROLanguageServer, ServiceBridge, SocketBridge). The REPL
        // writes to two pipes it does not own — the protocol pipe to the
        // client, and the capture pipes — so a reader going away must
        // surface as EPIPE on a `write` that the code can see, not as a
        // kill nobody can.
        signal(SIGPIPE, SIG_IGN)

        for sig in [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP] {
            signalMessages[sig] = Array("[aro repl] fatal signal \(sig); the REPL process is terminating\n".utf8)
            signal(sig) { received in
                REPLDiagnostics.reportSignal(received)
                // Restore the default and re-raise so the exit status still
                // says "killed by signal N" rather than pretending otherwise.
                signal(received, SIG_DFL)
                raise(received)
            }
        }

        atexit {
            REPLDiagnostics.reportUnexpectedExit()
        }
    }

    /// Record that the server is stopping because it was asked to.
    static func markShuttingDown() {
        shuttingDown = true
    }

    // MARK: - Reporters

    /// Async-signal-safe: writes a pre-built buffer to a raw descriptor
    /// and does nothing else.
    private static func reportSignal(_ sig: Int32) {
        guard diagnosticFD >= 0, let message = signalMessages[sig] else { return }
        message.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(diagnosticFD, base.advanced(by: written), buffer.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    /// An exit the client did not ask for. Runs at `atexit`, where
    /// allocation is still legal.
    private static func reportUnexpectedExit() {
        guard diagnosticFD >= 0, !shuttingDown else { return }
        let text = "[aro repl] the REPL exited without a shutdown request "
                 + "(stdin closed, or a statement called exit)\n"
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = write(diagnosticFD, base.advanced(by: written), buffer.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}

#endif
