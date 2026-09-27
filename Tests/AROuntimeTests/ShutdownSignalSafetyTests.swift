// ============================================================
// ShutdownSignalSafetyTests.swift
// ARORuntimeTests — Ctrl-C without undefined behaviour (GitLab #630)
// ============================================================
//
// The SIGINT handler took two `NSLock`s, published an event on the event-bus
// actor (spawning a `Task`) and resumed continuations — all from a POSIX
// signal context, where every one of those is undefined behaviour. A signal
// arriving while the main thread held either lock deadlocked the process
// instead of shutting it down, which is what an unreproducible "Ctrl-C hangs"
// report looks like.
//
// Delivery now goes through a `DispatchSourceSignal`, so the handler runs on
// an ordinary queue. That is not directly observable from a test — a unit
// test cannot raise a real SIGINT without ending the process — so what is
// asserted here is the machinery around it: that installing is idempotent,
// that the last handler wins, and that a handler doing the things the real
// one does is reached and completes.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Shutdown signal safety (GitLab #630)")
struct ShutdownSignalSafetyTests {

    @Test("Installing repeatedly leaves exactly one handler, and the last one wins")
    func installIsIdempotentAndLastWins() {
        // `install` is called from three sites. The handler is replaced each
        // time — the semantics `signal` had — but the dispatch sources must
        // be created once: three sources on SIGINT would call the handler
        // three times per Ctrl-C.
        AROSignalProbe.reset()
        ShutdownSignals.install { AROSignalProbe.first += 1 }
        ShutdownSignals.install { AROSignalProbe.second += 1 }
        ShutdownSignals.install { AROSignalProbe.second += 1 }

        ShutdownSignals.invokeForTesting()

        #expect(AROSignalProbe.first == 0)
        #expect(AROSignalProbe.second == 1)
    }

    @Test("A handler that locks and allocates completes")
    func aHandlerMayLockAndAllocate() {
        // The point of the change: this is exactly what the real handler
        // does, and in a signal context it was undefined behaviour rather
        // than merely slow.
        AROSignalProbe.reset()
        ShutdownSignals.install {
            AROSignalProbe.lock.lock()
            AROSignalProbe.first += 1
            AROSignalProbe.note = "shutting down"
            AROSignalProbe.lock.unlock()
        }

        ShutdownSignals.invokeForTesting()

        #expect(AROSignalProbe.first == 1)
        #expect(AROSignalProbe.note == "shutting down")
    }

    @Test("Invoking with nothing installed is safe")
    func invokeWithNoHandlerIsSafe() {
        // `ServerActions` asks `isActive` before installing its own, so the
        // window where nothing is installed is real.
        ShutdownSignals.invokeForTesting()
    }

    @Test("reset() clears the runtime but keeps the handlers installed")
    func resetKeepsTheHandlersInstalled() {
        // GitLab #630 reads this as a bug — "a second `register` never
        // reinstalls the handler". It is not: `register` assigns the runtime
        // *before* consulting `isSetup`, and the installed handler dispatches
        // through `RuntimeSignalHandler.shared`, so it always reaches the
        // current runtime. `isSetup` records that the process's signal
        // disposition has been changed and the dispatch sources created,
        // neither of which `reset` undoes — and `ServerActions` reads
        // `isActive` to decide whether to install handlers of its own, so
        // answering "no" after a reset would install a second set.
        let before = RuntimeSignalHandler.shared.isActive
        RuntimeSignalHandler.shared.reset()
        #expect(RuntimeSignalHandler.shared.isActive == before)
    }
}

/// A non-capturing landing pad: a shutdown handler becomes a C function
/// pointer and so cannot close over a local.
enum AROSignalProbe {
    nonisolated(unsafe) static var first = 0
    nonisolated(unsafe) static var second = 0
    nonisolated(unsafe) static var note = ""
    static let lock = NSLock()

    static func reset() {
        first = 0
        second = 0
        note = ""
    }
}
