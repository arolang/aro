// ============================================================
// ReplKernelClientTests.swift
// SOLARO — live round-trip against `aro repl --json` (ARO-0091)
// ============================================================
//
// Spawns the checkout's own `aro` binary and drives one execute
// through the real protocol — the same path a notebook cell takes.
// Skipped when no built `aro` is available (the SOLARO test job
// may run before the CLI product is built).

import Testing
import Foundation
@testable import SOLARO

@Suite("ReplKernelClient", .serialized)
struct ReplKernelClientTests {

    /// The checkout root, found by walking up from this file.
    private static var repoRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private static var builtAro: URL? {
        for config in ["debug", "release"] {
            let candidate = repoRoot
                .appendingPathComponent(".build/\(config)/aro")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// A scratch project *inside* `.build/` so the client's binary
    /// resolution (which walks up looking for `.build/<cfg>/aro`)
    /// lands on the checkout's own build.
    private func makeScratchProject() throws -> Project {
        let root = Self.repoRoot
            .appendingPathComponent(".build/repl-kernel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return Project(rootPath: root)
    }

    @Test("Executes a cell end-to-end: streams, display bundle, duration")
    @MainActor
    func executeRoundTrip() async throws {
        guard Self.builtAro != nil else { return }  // no CLI built — skip
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        await kernel.ensureStarted(project: project)
        #expect(kernel.state == .ready)

        var streamed = ""
        let outcome = await kernel.execute(
            code: """
            Log "from the test" to the <console>.
            Compute the <n: length> from "hello".
            """
        ) { _, text in streamed += text }

        #expect(outcome.status == "ok")
        #expect(outcome.plainText == "5")
        #expect(outcome.executionCount == 1)
        #expect(outcome.durationMs != nil)
        #expect(streamed.contains("from the test"))
        #expect(!outcome.kernelDied)

        kernel.shutdown()
    }

    @Test("An ARO error comes back split into evalue + traceback")
    @MainActor
    func errorRoundTrip() async throws {
        guard Self.builtAro != nil else { return }
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        await kernel.ensureStarted(project: project)

        let outcome = await kernel.execute(
            code: "Compute the <broken: not-a-real-qualifier> from \"x\"."
        ) { _, _ in }

        #expect(outcome.status == "error")
        #expect(outcome.errorValue?.isEmpty == false)
        #expect((outcome.traceback ?? []).isEmpty == false)
        #expect(!outcome.kernelDied)

        kernel.shutdown()
    }

    // MARK: - Lifecycle against a scripted fake kernel
    //
    // These tests need no built `aro`: they drive the client with a
    // /bin/sh stand-in that speaks just enough of the protocol (the
    // `ready` line) and — crucially — ignores SIGTERM, simulating a
    // kernel wedged inside the runtime (GitLab #527/#528).

    /// Writes an executable fake kernel that prints `ready`, traps
    /// SIGTERM, and then blocks forever. Returns its path.
    private func makeWedgedFakeKernel(in project: Project) throws -> String {
        let path = project.rootPath.appendingPathComponent("fake-kernel.sh")
        let script = """
        #!/bin/sh
        trap '' TERM
        printf '{"type":"ready","version":"fake"}\\n'
        while :; do sleep 1; done
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: path.path)
        return path.path
    }

    /// Best-effort SIGKILL for fake-kernel pids so a failed
    /// assertion can't leak a `while :; do sleep 1; done` loop.
    private func reap(_ pid: Int32?) {
        if let pid { kill(pid, SIGKILL) }
    }

    @Test("restart() escalates SIGTERM → SIGKILL instead of hanging on a wedged kernel")
    @MainActor
    func restartEscalatesToSigkill() async throws {
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        kernel.aroBinaryOverride = try makeWedgedFakeKernel(in: project)
        await kernel.ensureStarted(project: project)
        #expect(kernel.state == .ready)
        let oldPid = kernel.pid
        #expect(oldPid != nil)
        defer { reap(kernel.pid); reap(oldPid) }

        // Before GitLab #527 this awaited forever: the fake ignores
        // SIGTERM and the poll loop had no deadline. Now the client
        // SIGKILLs after its grace period and comes back ready.
        let started = Date()
        await kernel.restart(project: project)
        #expect(kernel.state == .ready)
        #expect(kernel.pid != nil)
        #expect(kernel.pid != oldPid)
        // 2s grace + reap + fresh start — well under the old ∞.
        #expect(Date().timeIntervalSince(started) < 8)
    }

    @Test("interrupt() on a wedged kernel still kills it (SIGKILL escalation)")
    @MainActor
    func interruptEscalatesToSigkill() async throws {
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        kernel.aroBinaryOverride = try makeWedgedFakeKernel(in: project)
        await kernel.ensureStarted(project: project)
        #expect(kernel.state == .ready)
        let pid = kernel.pid
        defer { reap(pid) }

        kernel.interrupt()
        // SIGTERM is trapped; only the escalation can get us to
        // `.dead`. Poll well past the grace period.
        let deadline = Date().addingTimeInterval(8)
        while kernel.state.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if case .dead = kernel.state {
            // reached via handleTermination after the SIGKILL
        } else {
            Issue.record("kernel state is \(kernel.state), expected .dead")
        }
    }

    @Test("A request that can't reach the kernel fails fast instead of leaking its continuation")
    @MainActor
    func deadStdinFailsTheRequest() async throws {
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        kernel.aroBinaryOverride = try makeWedgedFakeKernel(in: project)
        await kernel.ensureStarted(project: project)
        #expect(kernel.state == .ready)
        let pid = kernel.pid
        defer { reap(pid) }

        // Simulate the shutdown/stdin race from GitLab #528: stdin
        // is gone but state still says ready.
        kernel.dropStdinForTesting()

        // Run the execute on a child task and poll — before the fix
        // this await simply never returned (leaked continuation),
        // which would hang the whole suite.
        let holder = OutcomeHolder()
        Task { @MainActor in
            holder.outcome = await kernel.execute(code: "Log \"x\" to the <console>.") { _, _ in }
        }
        let deadline = Date().addingTimeInterval(5)
        while holder.outcome == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(holder.outcome?.kernelDied == true)
        #expect(holder.outcome?.errorName == "KernelDied")
        if case .dead = kernel.state {
            // the notebook UI sees a dead kernel, not a busy one
        } else {
            Issue.record("kernel state is \(kernel.state), expected .dead")
        }
    }

    @Test("shutdown() flips to .dead immediately so execute() can't race into the closed pipe")
    @MainActor
    func shutdownMarksKernelDead() async throws {
        let project = try makeScratchProject()
        defer { try? FileManager.default.removeItem(at: project.rootPath) }

        let kernel = ReplKernelClient()
        kernel.aroBinaryOverride = try makeWedgedFakeKernel(in: project)
        await kernel.ensureStarted(project: project)
        let pid = kernel.pid
        defer { reap(pid) }

        kernel.shutdown()
        if case .dead = kernel.state {
            // synchronous flip — no window for a racing execute()
        } else {
            Issue.record("kernel state is \(kernel.state), expected .dead")
        }

        let outcome = await kernel.execute(code: "Log \"x\" to the <console>.") { _, _ in }
        #expect(outcome.kernelDied)
    }
}

/// Mutable box for polling an unstructured task's result from the
/// main actor without racing it.
@MainActor
private final class OutcomeHolder {
    var outcome: ReplKernelClient.ExecOutcome?
}
