// ============================================================
// ApplicationEndLifecycleTests.swift
// ARO Runtime — Application-End runs once, and can see startup
// GitLab #628, #629
// ============================================================
//
// Both bugs went unnoticed for the same reason: nothing counted the
// executions, and nothing asked what the handler could see. A doubled `Log`
// looks like a log; a doubled store flush looks like a flush; a
// `Stop the <http-server>` against an already-stopped server looks like
// nothing at all until it throws.
//
// Observed through the event bus and a repository rather than through
// purpose-built actions. Registering a test-only `ActionImplementation` would
// put its verb in the process-wide `ActionRegistry`, and three parity suites
// assert that every registered verb appears in the editor grammars and that
// the action count matches the generated table — so a helper action makes
// unrelated suites fail, and only when the whole target runs.

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

@Suite("Application-End lifecycle (#628, #629)", .serialized)
struct ApplicationEndLifecycleTests {

    private func analyze(_ source: String) throws -> AnalyzedProgram {
        let result = Compiler().compile(source)
        #expect(!result.hasErrors, "\(result.diagnostics.map(\.message))")
        return result.analyzedProgram
    }

    @Test("Application-End: Success runs exactly once under runAndKeepAlive")
    func runsOnceWithKeepAlive() async throws {
        // `runAndKeepAlive` called `run`, which ran the handler, and then ran
        // it again itself — so every body ran twice per process (#628).
        let bus = EventBus()
        let starts = Counter()
        bus.subscribe(to: FeatureSetStartedEvent.self) { event in
            if event.featureSetName == "Application-End" { await starts.bump() }
        }

        let program = try analyze("""
        (Application-Start: Demo) {
            Log "start" to the <console>.
            Return an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            Log "stopping" to the <console>.
            Return an <OK: status> for the <shutdown>.
        }
        """)

        try await Runtime(eventBus: bus).runAndKeepAlive(program)
        _ = await bus.awaitPendingEvents(timeout: 2)
        let runs = await starts.count
        #expect(runs == 1, "Application-End ran \(runs) times")
    }

    @Test("Application-End sees what Application-Start published")
    func seesPublishedSymbols() async throws {
        // The shutdown executor was built with a fresh `GlobalSymbolStorage`,
        // and `Publish as` scopes a symbol to its business activity — which
        // for Application-End is `Success`, different from every other feature
        // set's. So the documented "graceful shutdown reads startup state"
        // pattern was unreachable (#629).
        let storage = InMemoryRepositoryStorage()
        let container = RuntimeContainer(eventBus: EventBus(), repositoryStorage: storage)

        let program = try analyze("""
        (Application-Start: Demo) {
            Create the <configured-endpoint> with "https://example.test".
            Publish as <endpoint> <configured-endpoint>.
            Return an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            Require the <endpoint> from the <Application-Start>.
            Store the <endpoint> into the <seen-repository>.
            Return an <OK: status> for the <shutdown>.
        }
        """)

        try await Runtime(eventBus: container.eventBus).runAndKeepAlive(program)

        let rows = await RuntimeContainer.default.repositoryStorage.retrieve(
            from: "seen-repository", businessActivity: "Success")
        let seen = rows.compactMap { $0 as? String }.first
            ?? rows.compactMap { ($0 as? [String: any Sendable])?["value"] as? String }.first
        #expect(seen == "https://example.test",
                "Application-End stored \(String(describing: rows))")
    }
}

/// Counts events. An actor because the bus delivers concurrently.
private actor Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}
