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
}
