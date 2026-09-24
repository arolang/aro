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

    /// Run `body` with a live compiled-mode context, as a binary would have.
    private func withCompiledContext(_ body: (UnsafeMutableRawPointer, RuntimeContext) -> Void) throws {
        let runtime = try #require(aro_runtime_init())
        defer { aro_runtime_shutdown(runtime) }

        let ctxPtr = try #require("Application-Start".withCString { name in
            "Env Demo".withCString { activity in
                aro_context_create_named(runtime, name, activity)
            }
        })
        let handle = Unmanaged<AROCContextHandle>.fromOpaque(ctxPtr).takeUnretainedValue()
        body(ctxPtr, handle.context)
    }

    @Test("A set variable is bound, under its own name")
    func bindsWhenSet() throws {
        setenv(Self.name, "secret123", 1)
        defer { unsetenv(Self.name) }

        try withCompiledContext { ctxPtr, context in
            Self.name.withCString { aro_context_require_environment(ctxPtr, $0) }
            #expect(context.resolveAny(Self.name) as? String == "secret123")
        }
    }

    @Test("An unset variable binds nothing, rather than binding empty")
    func bindsNothingWhenUnset() throws {
        unsetenv(Self.name)

        try withCompiledContext { ctxPtr, context in
            Self.name.withCString { aro_context_require_environment(ctxPtr, $0) }
            // Binding "" would let the program run on a silently wrong value.
            // Leaving it unbound makes the later read fail where the read is,
            // which is what ARO-0006 asks for.
            #expect(context.resolveAny(Self.name) == nil)
        }
    }

    @Test("The compiled answer is the interpreter's answer")
    func matchesTheInterpreter() throws {
        setenv(Self.name, "shared-value", 1)
        defer { unsetenv(Self.name) }

        // What `FeatureSetExecutor.executeRequireStatement` does.
        let interpreted = ProcessInfo.processInfo.environment[Self.name]

        try withCompiledContext { ctxPtr, context in
            Self.name.withCString { aro_context_require_environment(ctxPtr, $0) }
            #expect(context.resolveAny(Self.name) as? String == interpreted)
        }
    }

    @Test("An empty value is a value, and is bound")
    func emptyValueIsStillSet() throws {
        // `TOKEN=` is something somebody wrote, and it is distinguishable from
        // not setting it at all — the same rule `default` follows (#547).
        setenv(Self.name, "", 1)
        defer { unsetenv(Self.name) }

        try withCompiledContext { ctxPtr, context in
            Self.name.withCString { aro_context_require_environment(ctxPtr, $0) }
            #expect(context.resolveAny(Self.name) as? String == "")
        }
    }

    @Test("A null name is ignored rather than crashing")
    func nullNameIsSafe() throws {
        try withCompiledContext { ctxPtr, _ in
            aro_context_require_environment(ctxPtr, nil)
        }
    }
}
