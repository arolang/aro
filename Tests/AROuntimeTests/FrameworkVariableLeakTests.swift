// ============================================================
// FrameworkVariableLeakTests.swift
// ARO Runtime — a statement's modifiers end with the statement
// (GitLab #552)
// ============================================================
//
// `with { separator: "-" }` does not travel to the action as an
// argument; it binds `_with_` in the execution context and the
// action reads it back. That is only correct if the context is
// swept between statements, which is what
// `FeatureSetExecutor.executeAROStatement` does with
// `FrameworkVariables.transientKeys`.
//
// #552 was the compiled path skipping seven of those names, so the
// interpreter is the side that was already right. These tests pin
// it: they are the behaviour the compiled path is now required to
// match, and they fail if a future change to the shared constant
// silently drops a key that the interpreter depends on.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("A statement's modifiers do not outlive it (#552)")
struct FrameworkVariableLeakTests {

    /// Run a program and return what its `Return` handed back.
    private func run(_ source: String) async throws -> String {
        let compiled = Compiler.compile(source)
        guard compiled.isSuccess else {
            throw ActionError.runtimeError(
                "test program failed to compile: \(compiled.diagnostics)")
        }
        let response = try await ExecutionEngine().execute(compiled.analyzedProgram)
        return String(describing: response)
    }

    // MARK: - The issue's repro

    @Test("A second join with no `with` clause uses the default separator")
    func joinDoesNotInheritTheEarlierSeparator() async throws {
        // The exact program from #552. Compiled mode answered `c-d` here,
        // reusing the first join's `-`; interpreted mode answers `cd`, and
        // `cd` is the correct answer for a join with no separator given.
        let rendered = try await run("""
        (Application-Start: Probe) {
            Compute the <one> as List from ["a", "b"].
            Compute the <j1: join> from <one> with { separator: "-" }.
            Compute the <two> as List from ["c", "d"].
            Compute the <j2: join> from <two>.
            Return an <OK: status> with <j2>.
        }
        """)
        #expect(rendered.contains("cd"))
        #expect(!rendered.contains("c-d"),
                "the previous statement's separator leaked into this join: \(rendered)")
    }

    // MARK: - The same shape, one statement lower

    @Test("A `with` operand does not stand in for a missing one")
    func intersectWithoutAWithClauseIsAnError() async throws {
        // `intersect` needs a second operand and has no default, so a leaked
        // `_with_` turns a program that should stop into one that quietly
        // computes against the wrong list. Compiled mode printed `[]` here.
        await #expect(throws: (any Error).self) {
            _ = try await run("""
            (Application-Start: Probe) {
                Compute the <a> as List from [1, 2, 3].
                Compute the <b> as List from [2, 3, 4].
                Compute the <c> as List from [5, 6].
                Compute the <both: intersect> from <a> with <b>.
                Compute the <stale: intersect> from <c>.
                Return an <OK: status> with <stale>.
            }
            """)
        }
    }

    // MARK: - The sweep itself

    @Test("The sweep removes every transient key from a reused context",
          arguments: FrameworkVariables.transientKeys)
    func sweepClearsTheKey(key: String) {
        // Asserted against the context rather than through a program, because
        // most of these keys have no verb that would show the leak in output —
        // and a key with no such verb today acquires one tomorrow. `_by_var_`,
        // `_by_order_`, `_matching_` and `_recursive_` each entered the list
        // that way, one bug at a time.
        //
        // A flat context is the shape the compiled bridge presents: one
        // context per feature set, swept at the top of each statement. The
        // sweep is the only thing standing between statement N's modifiers and
        // statement N+1 there, so every name in the list has to be removable
        // by it.
        let context = RuntimeContext(featureSetName: "Test")
        context.bind(key, value: "stale")
        for transient in FrameworkVariables.transientKeys {
            context.unbind(transient)
        }
        let survivor = context.resolveAny(key)
        #expect(survivor == nil,
                Comment(rawValue: "\(key) survived the sweep as \(String(describing: survivor))"))
    }

    @Test("Consecutive statement scopes cannot see each other's modifiers")
    func statementScopesAreIsolated() {
        // The interpreter's second line of defence (ARO-0088 §2): framework
        // variables written in a statement's scope stay private to it, so the
        // next statement's scope starts without them even before the sweep
        // runs. Compiled mode has no equivalent, which is why its sweep has to
        // be complete.
        let featureSet = RuntimeContext(featureSetName: "Test")

        let first = featureSet.createStatementScope()
        first.bind("_with_", value: ["separator": "-"])

        let second = featureSet.createStatementScope()
        #expect(second.resolveAny("_with_") == nil,
                "a statement scope leaked `_with_` to the next statement")
    }
}
