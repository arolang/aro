// ============================================================
// ApplicationEndLifecycleTests.swift
// ARO Runtime — Application-End runs once, and can see startup
// GitLab #628, #629
// ============================================================
//
// Both bugs went unnoticed for the same reason: nothing counted the
// executions, and nothing asked what the handler could see. A doubled
// `Log` looks like a log; a doubled store flush looks like a flush; a
// `Stop the <http-server>` against an already-stopped server looks like
// nothing at all until it throws.

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
        let counter = ExecutionCounter()
        await counter.install()
        defer { Task { await counter.uninstall() } }

        let program = try analyze("""
        (Application-Start: Demo) {
            Log "start" to the <console>.
            Return an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            Count the <runs> for the <shutdown>.
            Return an <OK: status> for the <shutdown>.
        }
        """)

        let runtime = Runtime()
        try await runtime.runAndKeepAlive(program)
        let runs = await counter.count
        #expect(runs == 1, "Application-End ran \(runs) times")
    }

    @Test("Application-End sees what Application-Start published")
    func seesPublishedSymbols() async throws {
        // The shutdown executor was built with a fresh `GlobalSymbolStorage`,
        // so the documented "graceful shutdown reads startup state" pattern
        // failed with `undefinedVariable` (#629).
        let recorder = ValueRecorder()
        await recorder.install()
        defer { Task { await recorder.uninstall() } }

        let program = try analyze("""
        (Application-Start: Demo) {
            Create the <configured-endpoint> with "https://example.test".
            Publish as <endpoint> <configured-endpoint>.
            Return an <OK: status> for the <startup>.
        }

        (Application-End: Success) {
            Require the <endpoint> from the <Application-Start>.
            Record the <seen> for the <endpoint>.
            Return an <OK: status> for the <shutdown>.
        }
        """)

        let runtime = Runtime()
        try await runtime.runAndKeepAlive(program)
        let seen = await recorder.seen
        #expect(seen == "https://example.test",
                "Application-End saw \(String(describing: seen))")
    }
}

/// Counts how many times its verb ran.
private actor ExecutionCounter {
    static let shared = ExecutionCounter()
    private(set) var count = 0
    func bump() { count += 1 }
    func install() { CountAction.sink = self; ActionRegistry.shared.register(CountAction.self) }
    func uninstall() { CountAction.sink = nil }
}

private struct CountAction: ActionImplementation {
    nonisolated(unsafe) static var sink: ExecutionCounter?
    static let role: ActionRole = .own
    static let verbs: Set<String> = ["count"]
    static let validPrepositions: Set<Preposition> = [.for, .with]
    init() {}
    func execute(result: ResultDescriptor, object: ObjectDescriptor,
                 context: ExecutionContext) async throws -> any Sendable {
        await Self.sink?.bump()
        return true
    }
}

/// Records the value of the object it was given.
private actor ValueRecorder {
    private(set) var seen: String?
    func record(_ value: String?) { seen = value }
    func install() { RecordAction.sink = self; ActionRegistry.shared.register(RecordAction.self) }
    func uninstall() { RecordAction.sink = nil }
}

private struct RecordAction: ActionImplementation {
    nonisolated(unsafe) static var sink: ValueRecorder?
    static let role: ActionRole = .own
    static let verbs: Set<String> = ["record"]
    static let validPrepositions: Set<Preposition> = [.for, .with]
    init() {}
    func execute(result: ResultDescriptor, object: ObjectDescriptor,
                 context: ExecutionContext) async throws -> any Sendable {
        await Self.sink?.record(context.resolveAny(object.base) as? String)
        return true
    }
}
