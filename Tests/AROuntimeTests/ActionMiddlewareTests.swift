// ============================================================
// ActionMiddlewareTests.swift
// ARO Runtime - Action Middleware / Hooks (GitLab #107)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

/// Thread-safe recorder, since middleware may run off the test's thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        entries.append(entry)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    var count: Int { all.count }
}

/// Business activity of the test program. Hooks below key on it so they stay
/// inert for anything else running in the same process.
private let testActivity = "Middleware Test"

/// Wraps a middleware body so it only acts on the test program.
///
/// `ActionRegistry.shared` is a process-wide singleton and other suites execute
/// ARO in parallel with this one. A hook that short-circuits or throws on
/// `compute` would corrupt those tests during the window it is registered, so
/// every hook passes straight through for any other business activity.
private func scoped(_ body: @escaping ActionMiddleware) -> ActionMiddleware {
    { invocation, context, next in
        guard context.businessActivity == testActivity else { return try await next() }
        return try await body(invocation, context, next)
    }
}

/// Runs an ARO program.
///
/// Middleware lives on the process-wide `ActionRegistry.shared`, so every test
/// removes what it registered — `.serialized` keeps concurrent tests in this
/// suite from seeing each other's hooks, and `scoped` keeps them from reaching
/// other suites.
private func runProgram(_ source: String) async throws {
    let compiled = Compiler.compile(source)
    guard compiled.isSuccess else {
        throw ActionError.runtimeError("test program failed to compile: \(compiled.diagnostics)")
    }
    let engine = ExecutionEngine()
    _ = try await engine.execute(compiled.analyzedProgram)
}

/// `Create the <x> with 21.` and `Compute the <y> from <x> * 2.` carry no result
/// qualifier, so the interpreter binds them as plain expressions without
/// dispatching an action — middleware cannot see those. `Compute the <n: length>`
/// does dispatch, as do Log and Return. The program exercises both shapes.
private let simpleProgram = """
(Application-Start: Middleware Test) {
    Create the <x> with 21.
    Compute the <y> from <x> * 2.
    Create the <s> with "abcd".
    Compute the <n: length> from <s>.
    Log <y> to the <console>.
    Return an <OK: status> for the <t>.
}
"""

// MARK: - All middleware tests share the process-wide ActionRegistry.shared,
// so they live in ONE serialized suite. Split across suites they would run in
// parallel with each other and each teardown would wipe the others' hooks.

@Suite("Action Middleware", .serialized)
struct ActionMiddlewareTests {

    @Test("No middleware is registered by default")
    func testNoneByDefault() {
        ActionRegistry.shared.removeAllMiddleware()

        #expect(!ActionRegistry.shared.hasMiddleware)
    }

    @Test("Registering reports hasMiddleware, removing clears it")
    func testRegisterAndRemove() {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()

        let token = ActionRegistry.shared.addMiddleware { _, _, next in try await next() }
        #expect(ActionRegistry.shared.hasMiddleware)

        #expect(ActionRegistry.shared.removeMiddleware(token))
        #expect(!ActionRegistry.shared.hasMiddleware)
    }

    @Test("Removing an already-removed token reports false")
    func testRemoveTwice() {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()

        let token = ActionRegistry.shared.addMiddleware { _, _, next in try await next() }
        #expect(ActionRegistry.shared.removeMiddleware(token))
        #expect(!ActionRegistry.shared.removeMiddleware(token))
    }

    @Test("removeAllMiddleware clears every registration")
    func testRemoveAll() {
        ActionRegistry.shared.removeAllMiddleware()
        ActionRegistry.shared.addMiddleware { _, _, next in try await next() }
        ActionRegistry.shared.addMiddleware { _, _, next in try await next() }

        ActionRegistry.shared.removeAllMiddleware()

        #expect(!ActionRegistry.shared.hasMiddleware)
    }

    // MARK: - Execution

    @Test("Middleware observes every action in the program")
    func testObservesActions() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(scoped { invocation, _, next in
            recorder.record(invocation.verb)
            return try await next()
        })

        try await runProgram(simpleProgram)

        // Every dispatched action is seen, including ones that would otherwise
        // take the synchronous fast path, and the verb is canonical lowercase.
        #expect(recorder.all.contains("compute"))
        #expect(recorder.all.contains("log"))
        #expect(recorder.all.contains("return"))
    }

    @Test("Expression-only Create/Compute statements dispatch no action")
    func testExpressionOnlyStatementsAreNotSeen() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(scoped { invocation, _, next in
            recorder.record(invocation.verb)
            return try await next()
        })

        try await runProgram(simpleProgram)

        // Documented limitation, asserted so it cannot change silently: `create`
        // never appears because both Create statements bind an expression
        // directly without executing CreateAction.
        #expect(!recorder.all.contains("create"))
        // The qualified Compute *does* dispatch, so `compute` appears exactly once.
        #expect(recorder.all.filter { $0 == "compute" }.count == 1)
    }

    @Test("Verb filter restricts which actions are seen")
    func testVerbFilter() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { invocation, _, next in
            recorder.record(invocation.verb)
            return try await next()
        })

        try await runProgram(simpleProgram)

        #expect(recorder.all == ["compute"])
    }


    @Test("Verb filter canonicalizes synonyms")
    func testVerbFilterCanonicalizes() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        // "print" is a synonym of "log" — filtering on either must match.
        ActionRegistry.shared.addMiddleware(for: ["print"], scoped { invocation, _, next in
            recorder.record(invocation.verb)
            return try await next()
        })

        try await runProgram(simpleProgram)

        #expect(recorder.all == ["log"])
    }

    @Test("Middleware runs outermost-first in registration order")
    func testOrdering() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, next in
            recorder.record("outer-in")
            let value = try await next()
            recorder.record("outer-out")
            return value
        })
        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, next in
            recorder.record("inner-in")
            let value = try await next()
            recorder.record("inner-out")
            return value
        })

        try await runProgram(simpleProgram)

        #expect(recorder.all == ["outer-in", "inner-in", "inner-out", "outer-out"])
    }

    @Test("Middleware can substitute the action's result")
    func testResultSubstitution() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, next in
            let value = try await next()
            recorder.record("saw \(value)")
            return 999
        })

        try await runProgram(simpleProgram)

        // The dispatched Compute is `<n: length> from <s>` where s = "abcd".
        #expect(recorder.all == ["saw 4"])
    }

    @Test("Middleware can short-circuit without invoking the action")
    func testShortCircuit() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, _ in
            recorder.record("short-circuited")
            return 7
        })

        try await runProgram(simpleProgram)

        #expect(recorder.all == ["short-circuited"])
    }

    @Test("Middleware can call next more than once (retry)")
    func testRetry() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, next in
            _ = try await next()
            recorder.record("attempt-1")
            let second = try await next()
            recorder.record("attempt-2")
            return second
        })

        try await runProgram(simpleProgram)

        #expect(recorder.all == ["attempt-1", "attempt-2"])
    }

    @Test("A throwing middleware propagates and aborts the action")
    func testThrowingMiddleware() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { invocation, _, _ in
            throw ActionError.runtimeError("Unauthorized: \(invocation.verb)")
        })
        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { _, _, next in
            recorder.record("should-not-run")
            return try await next()
        })

        await #expect(throws: (any Error).self) {
            try await runProgram(simpleProgram)
        }
        // The outer hook threw, so the inner one never ran.
        #expect(recorder.count == 0)
    }

    @Test("Invocation exposes the statement's descriptors")
    func testInvocationDescriptors() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        ActionRegistry.shared.addMiddleware(for: ["compute"], scoped { invocation, _, next in
            recorder.record("result=\(invocation.result.base)")
            recorder.record("prep=\(invocation.object.preposition.rawValue)")
            return try await next()
        })

        try await runProgram(simpleProgram)

        // The dispatched Compute is `Compute the <n: length> from <s>.`
        #expect(recorder.all.contains("result=n"))
        #expect(recorder.all.contains("prep=from"))
    }

    @Test("An unknown verb still reports unknownAction, not a middleware error")
    func testUnknownVerbUnaffected() async throws {
        defer { ActionRegistry.shared.removeAllMiddleware() }
        ActionRegistry.shared.removeAllMiddleware()
        let recorder = Recorder()

        // Deliberately unscoped: this hook only records and forwards, so it is
        // harmless to other suites, and scoping it would make the assertion below
        // pass for the wrong reason.
        ActionRegistry.shared.addMiddleware { _, _, next in
            recorder.record("ran")
            return try await next()
        }

        let result = ResultDescriptor(base: "r", span: SourceSpan(at: SourceLocation()))
        let object = ObjectDescriptor(
            preposition: .from, base: "x", span: SourceSpan(at: SourceLocation())
        )
        let context = RuntimeContext(featureSetName: "Test")

        await #expect(throws: ActionError.self) {
            _ = try await ActionRegistry.shared.execute(
                verb: "no-such-verb-107", result: result, object: object, context: context
            )
        }
        // The target is resolved before the chain is built, so no hook ran.
        #expect(recorder.count == 0)
    }

    // MARK: - Zero Impact When Unused

    @Test("Programs behave identically with no middleware registered")
    func testUnchangedWithoutMiddleware() async throws {
        ActionRegistry.shared.removeAllMiddleware()

        // Baseline sanity: the program runs clean and the sync fast path is live.
        #expect(!ActionRegistry.shared.hasMiddleware)
        try await runProgram(simpleProgram)
    }

    @Test("Removing all middleware restores the synchronous fast path")
    func testFastPathRestored() async throws {
        ActionRegistry.shared.removeAllMiddleware()
        let token = ActionRegistry.shared.addMiddleware { _, _, next in try await next() }
        #expect(ActionRegistry.shared.hasMiddleware)

        ActionRegistry.shared.removeMiddleware(token)

        #expect(!ActionRegistry.shared.hasMiddleware)
        try await runProgram(simpleProgram)
    }
}
