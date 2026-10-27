// ============================================================
// ObjectSlotWithClauseTests.swift
// ARO Runtime — the two halves of GitLab #887
// ============================================================
//
// `Start the <socket-server> with { port: 9123 }.` puts its config map in
// the object slot, because there is nowhere else for it to go. Two things
// have to hold for that to work, and in a compiled binary neither did.
//
//  1. The value has to reach `_with_`, not only `_expression_`. The IR half
//     is `ObjectSlotWithClauseCodeGenTests`; the half here is *why* that
//     matters — `resolvePort` reads a config map out of `_with_` and will
//     not take one from `_expression_`, so the bind is load-bearing rather
//     than belt-and-braces.
//
//  2. It must not then reach a user-defined action called by that statement.
//     A compiled binary has no per-statement scopes, so framework variables
//     are bound straight onto the feature set's own context — which for
//     `Application-Start` is the application root. A callee marks itself a
//     call-frame root and jumps *to that root* on lookup, skipping the
//     caller's locals exactly as designed, and landing on the one context
//     holding the modifiers. `Application.IngestOrders the <bronze> with { }.`
//     therefore left an empty map in `_with_` that the first
//     `Store … into the <repo>.` inside the callee read as an inline
//     payload (#515) — six rows became one, silently.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("An object-slot `with` clause (#887)")
struct ObjectSlotWithClauseTests {

    // MARK: - 1. `_with_` is what carries a config map

    @Test("A config map in _with_ selects the port")
    func withMapSelectsPort() {
        let context = RuntimeContext(featureSetName: "T", businessActivity: "Test")
        context.bind("_with_", value: ["port": 9123] as [String: any Sendable])

        #expect(context.resolvePort(specifiers: [], defaultPort: 9000) == 9123)
    }

    @Test("The same map in _expression_ alone does NOT select the port")
    func expressionMapIsNotEnough() {
        // This is the whole reason the compiled path had to start binding
        // `_with_`. `resolvePort` consults `_expression_` only as a bare Int,
        // so a `{ port: … }` that arrives there and nowhere else falls through
        // to the default — and the server starts, reports success, and listens
        // on the wrong port. Nothing errors, which is what made it expensive.
        let context = RuntimeContext(featureSetName: "T", businessActivity: "Test")
        context.bind("_expression_", value: ["port": 9123] as [String: any Sendable])

        #expect(context.resolvePort(specifiers: [], defaultPort: 9000) == 9000,
                "if this starts passing, the fallback changed and the #887 bind may be redundant")
    }

    @Test("A bare Int in _expression_ still selects the port")
    func expressionIntStillWorks() {
        // The path that always worked, pinned so the fix above cannot be
        // "simplified" by removing it.
        let context = RuntimeContext(featureSetName: "T", businessActivity: "Test")
        context.bind("_expression_", value: 9123)

        #expect(context.resolvePort(specifiers: [], defaultPort: 9000) == 9123)
    }

    // MARK: - 2. A callee does not inherit the caller's modifiers

    @Test("A call-frame root sees the application root's framework variables")
    func calleeSeesRootBindings() {
        // Not a bug — the documented lookup rule, pinned because it is the
        // mechanism behind the second half of #887. A callee skips the
        // caller's locals by jumping to the application root; anything bound
        // on the root is therefore visible to it, framework variables
        // included.
        let root = RuntimeContext(featureSetName: "Application-Start",
                                  businessActivity: "App")
        root.bind("_with_", value: ["port": 1] as [String: any Sendable])

        let callee = RuntimeContext(featureSetName: "Ingest",
                                    businessActivity: "Action",
                                    parent: root)
        callee.markCallFrameRoot()

        #expect(callee.resolveAny("_with_") != nil,
                "the jump to the application root is what exposes the caller's modifiers")
    }

    @Test("Clearing the caller's transients is what stops the leak")
    func clearingTheCallerIsolatesTheCallee() {
        // What `aro_register_user_action` now does before invoking the body.
        // The caller's `with` clause has already been read to build `<input>`
        // by that point, so clearing it takes nothing anybody still needs.
        let root = RuntimeContext(featureSetName: "Application-Start",
                                  businessActivity: "App")
        root.bind("_with_", value: ["port": 1] as [String: any Sendable])
        root.clearTransientFrameworkVariables()

        let callee = RuntimeContext(featureSetName: "Ingest",
                                    businessActivity: "Action",
                                    parent: root)
        callee.markCallFrameRoot()

        #expect(callee.resolveAny("_with_") == nil,
                "a callee must not see the statement modifiers of the call that reached it")
    }

    @Test("Every transient is cleared, not just _with_")
    func clearingCoversTheWholeList() {
        // `_with_` is the one that bit, because Store reads its *presence*.
        // The rest are no more entitled to cross a call boundary, and the
        // sweep is defined over `FrameworkVariables.transientKeys` precisely
        // so this cannot be a per-name decision.
        let root = RuntimeContext(featureSetName: "Application-Start",
                                  businessActivity: "App")
        for key in FrameworkVariables.transientKeys {
            root.bind(key, value: "leaked")
        }
        root.clearTransientFrameworkVariables()

        let callee = RuntimeContext(featureSetName: "Ingest",
                                    businessActivity: "Action",
                                    parent: root)
        callee.markCallFrameRoot()

        for key in FrameworkVariables.transientKeys {
            #expect(callee.resolveAny(key) == nil, "\(key) crossed the call boundary")
        }
    }

    @Test("Ordinary bindings are untouched")
    func nonTransientsSurvive() {
        // The sweep must not take the caller's real values with it — a
        // published symbol or an application-level binding is exactly what a
        // callee is supposed to be able to see.
        let root = RuntimeContext(featureSetName: "Application-Start",
                                  businessActivity: "App")
        root.bind("catalogue", value: "intact")
        root.bind("_with_", value: 1)
        root.clearTransientFrameworkVariables()

        let callee = RuntimeContext(featureSetName: "Ingest",
                                    businessActivity: "Action",
                                    parent: root)
        callee.markCallFrameRoot()

        #expect(callee.resolveAny("catalogue") as? String == "intact")
        #expect(callee.resolveAny("_with_") == nil)
    }
}
