// ============================================================
// ExecTimeoutTests.swift
// ARO Runtime - Exec timeout enforcement (GitLab #586)
// ============================================================
//
// The timeout used to be carried and dropped: `{ command: "sleep 5",
// timeout: 1000 }` ran for the full five seconds and reported exit code 0.
// These tests pin the enforcement down — including that a child which ignores
// SIGTERM is still stopped, and that work the command backgrounded goes with it.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Exec Timeout Enforcement")
struct ExecTimeoutTests {

    /// Wall-clock seconds spent running `config`, alongside its result.
    private func timed(_ config: ExecConfig) -> (result: ExecResult, seconds: Double) {
        let start = Date()
        let result = ExecuteAction.runCommandSyncForTesting(config)
        return (result, Date().timeIntervalSince(start))
    }

    private func uniqueMarker(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-586-\(label)-\(UUID().uuidString)")
            .path
    }

    /// The ceiling a "the timeout bounded it" assertion may use.
    ///
    /// Enforcement costs `timeout`, plus — in the worst case — the SIGTERM
    /// grace before SIGKILL (`terminationGrace`, 2s) and then the wait for a
    /// pipe a surviving grandchild still holds (`orphanedPipeGrace`, 2s). So
    /// ~4.2s is legitimate for a 200ms timeout, and a tighter bound asserts
    /// the host's signal-delivery latency rather than the contract. It did:
    /// `< 1.5` passed on Darwin, where Foundation puts the child in a process
    /// group of its own and the group kill lands at once, and failed on the
    /// Linux CI runner at 2.2s — exactly `timeout` plus one full grace —
    /// because there the child shares our group, so `childProcessGroup` returns
    /// nil by design and only the direct SIGTERM is sent.
    ///
    /// The commands under test sleep far longer than this, so a pass still
    /// proves the caller was released by the timeout and not by the command.
    private static let enforcementCeiling: Double = 6.0

    @Test("A command that outruns its timeout returns exit code -1, quickly")
    func testTimeoutReturnsMinusOne() {
        let (result, seconds) = timed(ExecConfig(command: "sleep 30", timeout: 200))

        #expect(result.exitCode == -1)
        #expect(result.error)
        #expect(result.message.contains("timed out"))
        // The whole point: the caller is released at its timeout, not at the
        // command's own pace. 30s of `sleep` returning in seconds can only be
        // the timeout.
        #expect(seconds < Self.enforcementCeiling,
                "took \(seconds)s — the timeout did not bound the child")
    }

    @Test("A command that finishes inside its timeout is unaffected")
    func testFastCommandUnaffected() {
        let timeoutMilliseconds = 5000
        let (result, seconds) = timed(
            ExecConfig(command: "echo inside", timeout: timeoutMilliseconds)
        )

        #expect(result.exitCode == 0)
        #expect(!result.error)
        #expect(result.output == "inside")
        #expect(result.message == "Command executed successfully")

        // Bounded by the *timeout*, not by how fast the host can spawn a
        // process. The four assertions above already prove the command ran to
        // completion and was not killed — had the timeout fired, the exit code
        // would be -1 and `error` true. What is left to rule out is an
        // implementation that always waits the timeout out before reporting,
        // so the bound only has to sit below 5s with room to spare.
        //
        // `< 2.0` did not: `echo` took 2.20s on a loaded Linux runner and
        // failed the job on an unrelated branch. Process-spawn latency under
        // load is not the contract, the same lesson `enforcementCeiling`
        // above records for the other direction.
        let waitedOutTheTimeout = Double(timeoutMilliseconds) / 1000.0 - 1.0
        #expect(seconds < waitedOutTheTimeout,
                "took \(seconds)s — the caller looks held until the timeout")
    }

    @Test("Output produced before the timeout is still returned")
    func testPartialOutputSurvivesTimeout() {
        let (result, _) = timed(ExecConfig(command: "echo partial; sleep 3", timeout: 300))

        #expect(result.exitCode == -1)
        #expect(result.output.contains("partial"))
    }

    @Test("A SIGTERM-ignoring child is killed anyway")
    func testSigtermIgnoringChildIsKilled() {
        // `trap "" TERM` makes the shell itself ignore SIGTERM, and the busy loop
        // keeps it in the shell rather than in a signal-killable child — so only
        // the SIGKILL escalation can end this process.
        let (result, seconds) = timed(
            ExecConfig(command: #"trap "" TERM; while :; do :; done"#, timeout: 200)
        )

        #expect(result.exitCode == -1)
        #expect(result.error)
        // Timeout + the two-second SIGTERM grace, with room for a loaded machine.
        #expect(seconds < 8.0, "took \(seconds)s — SIGKILL escalation did not fire")
    }

    @Test("Work the command backgrounded is killed with it")
    func testBackgroundedGrandchildIsKilled() throws {
        let marker = uniqueMarker("grandchild")
        defer { try? FileManager.default.removeItem(atPath: marker) }

        // The subshell outlives its parent shell unless the whole process group
        // is signalled — it only touches the marker a full second after the
        // 200ms timeout has already stopped the shell.
        let (result, _) = timed(
            ExecConfig(command: "(sleep 1; touch \(marker)) & sleep 5", timeout: 200)
        )

        #expect(result.exitCode == -1)
        // Well past the moment the orphan would have written.
        Thread.sleep(forTimeInterval: 2.0)
        #expect(
            !FileManager.default.fileExists(atPath: marker),
            "a backgrounded grandchild survived the timeout and kept working"
        )
    }

    @Test("timeout: 0 means no timeout")
    func testZeroTimeoutDisablesTheBound() {
        let (result, seconds) = timed(ExecConfig(command: "sleep 1", timeout: 0))

        #expect(result.exitCode == 0)
        #expect(!result.error)
        #expect(seconds >= 0.9, "took \(seconds)s — the child was cut short")
    }

    @Test("A negative timeout is treated as no timeout, not as an instant one")
    func testNegativeTimeoutDisablesTheBound() {
        let (result, _) = timed(ExecConfig(command: "sleep 1", timeout: -1))

        #expect(result.exitCode == 0)
        #expect(!result.error)
    }

    @Test("The default timeout is 30 seconds and applies to every construction")
    func testDefaultTimeout() {
        #expect(ExecConfig(command: "true").timeout == 30000)
        #expect(ExecConfig.direct(argv: ["true"]).timeout == 30000)

        // A command well inside the default is not disturbed by it.
        let (result, _) = timed(ExecConfig(command: "sleep 0.2"))
        #expect(result.exitCode == 0)
    }

    @Test("The shell-free argv form is bounded too")
    func testArgvFormIsBounded() {
        let (result, seconds) = timed(
            ExecConfig.direct(argv: ["sleep", "30"], timeout: 200)
        )

        #expect(result.exitCode == -1)
        #expect(seconds < Self.enforcementCeiling,
                "took \(seconds)s — argv execution ignored the timeout")
    }

    @Test("A configuration object's timeout is read whatever number spelling it uses")
    func testTimeoutFieldCoercion() {
        #expect(ExecuteAction.timeoutMilliseconds(1000) == 1000)
        #expect(ExecuteAction.timeoutMilliseconds(1500.0) == 1500)
        #expect(ExecuteAction.timeoutMilliseconds("250") == 250)
        #expect(ExecuteAction.timeoutMilliseconds(0) == 0)
        // Absent or unreadable: the documented default, never a silent zero.
        #expect(ExecuteAction.timeoutMilliseconds(nil) == 30000)
        #expect(ExecuteAction.timeoutMilliseconds("soon") == 30000)
    }

    @Test("Exec never defers, so a timeout surfaces at its own statement")
    func testExecIsNotDeferrable() {
        // ARO-0088: a deferred action's failure shows up at the first read of its
        // result. An Exec that timed out must report where it was written.
        for verb in ExecuteAction.verbs {
            #expect(!LazyActionPolicy.deferrable(verb), "\(verb) became deferrable")
        }
    }
}
