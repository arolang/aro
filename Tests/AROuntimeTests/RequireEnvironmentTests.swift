// ============================================================
// RequireEnvironmentTests.swift
// ARO Runtime — `Require … from the <environment>` in both modes
// GitLab #854
// ============================================================
//
// The compiled path emitted an `extract` whose object was the bare noun
// `environment`, which no action understands. The statement failed with
// `Undefined variable: 'environment'` — and the binary still exited `[OK]`,
// because a deferred failure is reported on a line of its own and the program
// carries on.
//
// That is the worst shape this bug can take: a service reading its token from
// the environment starts successfully, behaves as though the variable were
// unset, and passes `aro check`. The failure is invisible in the artefact you
// hand to someone else.
//
// These go through the real C entry points — `aro_runtime_init`,
// `aro_context_create_named`, `aro_context_require_environment` — because the
// bug was in the generated call, not in any Swift-level helper.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Require from the environment (#854)", .serialized)
struct RequireEnvironmentTests {

    /// A name no real environment holds.
    private static let name = "ARO_854_TEST_TOKEN"

    private struct BridgeCallFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// What `Require the <name> from the <environment>` bound in a live
    /// compiled-mode context: `.none` when it bound nothing, `.some(nil)` when
    /// it bound something that is not a string.
    ///
    /// The C entry points run on a GCD thread, as they would on a binary's main
    /// thread — never on the cooperative pool. `aro_runtime_init` starts a Task
    /// and blocks until it finishes, so calling it from a synchronous test
    /// parked a pool thread waiting for work that needed one; on a 3-core
    /// GitHub runner that stalled every async test in the process.
    private func requireInCompiledContext(_ name: String?) async throws -> String?? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                guard let runtime = aro_runtime_init() else {
                    continuation.resume(throwing: BridgeCallFailed(description: "aro_runtime_init returned nil"))
                    return
                }
                let ctxPtr = "Application-Start".withCString { featureSet in
                    "Env Demo".withCString { activity in
                        aro_context_create_named(runtime, featureSet, activity)
                    }
                }
                guard let ctxPtr else {
                    aro_runtime_shutdown(runtime)
                    continuation.resume(throwing: BridgeCallFailed(description: "aro_context_create_named returned nil"))
                    return
                }
                if let name {
                    name.withCString { aro_context_require_environment(ctxPtr, $0) }
                } else {
                    aro_context_require_environment(ctxPtr, nil)
                }
                let context = Unmanaged<AROCContextHandle>.fromOpaque(ctxPtr).takeUnretainedValue().context
                let bound = context.resolveAny(Self.name).map { $0 as? String }
                // Shut down before resuming, so the next serialized test never
                // overlaps this runtime's teardown.
                aro_runtime_shutdown(runtime)
                continuation.resume(returning: bound)
            }
        }
    }

    @Test("A set variable is bound, under its own name")
    func bindsWhenSet() async throws {
        setenv(Self.name, "secret123", 1)
        defer { unsetenv(Self.name) }

        let bound = try await requireInCompiledContext(Self.name)
        #expect(bound == "secret123")
    }

    @Test("An unset variable binds nothing, rather than binding empty")
    func bindsNothingWhenUnset() async throws {
        unsetenv(Self.name)

        let bound = try await requireInCompiledContext(Self.name)
        // Binding "" would let the program run on a silently wrong value.
        // Leaving it unbound makes the later read fail where the read is,
        // which is what ARO-0006 asks for.
        #expect(bound == .none)
    }

    @Test("The compiled answer is the interpreter's answer")
    func matchesTheInterpreter() async throws {
        setenv(Self.name, "shared-value", 1)
        defer { unsetenv(Self.name) }

        // What `FeatureSetExecutor.executeRequireStatement` does.
        let interpreted = ProcessInfo.processInfo.environment[Self.name]

        let bound = try await requireInCompiledContext(Self.name)
        #expect(bound == .some(interpreted))
    }

    @Test("An empty value is a value, and is bound")
    func emptyValueIsStillSet() async throws {
        // `TOKEN=` is something somebody wrote, and it is distinguishable from
        // not setting it at all — the same rule `default` follows (#547).
        setenv(Self.name, "", 1)
        defer { unsetenv(Self.name) }

        let bound = try await requireInCompiledContext(Self.name)
        #expect(bound == "")
    }

    @Test("A null name is ignored rather than crashing")
    func nullNameIsSafe() async throws {
        unsetenv(Self.name)
        let bound = try await requireInCompiledContext(nil)
        #expect(bound == .none)
    }
}
