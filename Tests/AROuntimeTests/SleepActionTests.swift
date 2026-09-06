// ============================================================
// SleepActionTests.swift
// ARO Runtime — Sleep duration units resolve at run time
// (GitLab #502)
// ============================================================
//
// The parser stores a unit word ("ms", "s", "m", "seconds", …) as
// the Sleep statement's object base; SleepAction multiplies by the
// entry `DurationUnitCatalog` holds for it. These tests run real
// programs and time them, so they catch the table and the plumbing
// both — a unit the parser accepts but the runtime ignores would
// sleep 250 seconds here, not 250 milliseconds.
//
// Bounds are deliberately loose: each sleep must last at least what
// was asked (a runtime cannot legally wake early) and less than a
// ceiling that only trips when a multiplier is wrong by orders of
// magnitude (ms read as seconds, m not applied). Wall-clock
// tightness would measure the CI runner, not the runtime — see the
// note in DeferredExecutionTests.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Sleep duration units (GitLab #502)", .serialized)
struct SleepActionTests {

    /// Compiles and runs a one-feature-set program, returning the
    /// wall-clock seconds the run took.
    private func timeProgram(_ statement: String) async throws -> TimeInterval {
        let compiled = Compiler.compile("""
        (Application-Start: Sleep Test) {
            \(statement)
            Return an <OK: status> for the <t>.
        }
        """)
        guard compiled.isSuccess else {
            throw ActionError.runtimeError(
                "test program failed to compile: \(compiled.diagnostics)")
        }
        let engine = ExecutionEngine()
        let start = Date()
        _ = try await engine.execute(compiled.analyzedProgram)
        return Date().timeIntervalSince(start)
    }

    @Test("for 250ms sleeps a quarter second, not 250 seconds")
    func testMillisecondSuffix() async throws {
        let elapsed = try await timeProgram("Sleep the <pause> for 250ms.")
        #expect(elapsed >= 0.24, "woke early: \(elapsed)s")
        #expect(elapsed < 10, "ms unit not applied — slept \(elapsed)s")
    }

    @Test("for 500 milliseconds — spelled-out unit, same table")
    func testSpelledOutMilliseconds() async throws {
        let elapsed = try await timeProgram("Sleep the <pause> for 500 milliseconds.")
        #expect(elapsed >= 0.49, "woke early: \(elapsed)s")
        #expect(elapsed < 10, "milliseconds unit not applied — slept \(elapsed)s")
    }

    @Test("for 0.005m is 300ms — the minute suffix multiplies by 60")
    func testMinuteSuffix() async throws {
        // 0.005 minutes: long enough to prove x60 happened (a bare
        // 0.005 would return almost instantly), short enough for CI.
        let elapsed = try await timeProgram("Sleep the <pause> for 0.005m.")
        #expect(elapsed >= 0.29, "minute multiplier missing: \(elapsed)s")
        #expect(elapsed < 10, "minute unit misread: \(elapsed)s")
    }

    @Test("for 1.5s — fractional value with a suffix")
    func testFractionalSecondSuffix() async throws {
        let elapsed = try await timeProgram("Sleep the <pause> for 1.5s.")
        #expect(elapsed >= 1.49, "woke early: \(elapsed)s")
        #expect(elapsed < 15, "second unit misread: \(elapsed)s")
    }

    @Test("with 300 ms — the with preposition carries units too")
    func testWithPrepositionUnit() async throws {
        let elapsed = try await timeProgram("Sleep the <pause> with 300 ms.")
        #expect(elapsed >= 0.29, "woke early: \(elapsed)s")
        #expect(elapsed < 10, "ms unit not applied via with: \(elapsed)s")
    }

    @Test("Bare number stays seconds — backward compatible")
    func testBareNumberIsSeconds() async throws {
        let elapsed = try await timeProgram("Sleep the <pause> for 1.")
        #expect(elapsed >= 0.99, "bare literal no longer seconds: \(elapsed)s")
    }
}
