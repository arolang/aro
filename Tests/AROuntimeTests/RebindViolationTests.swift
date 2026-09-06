// ============================================================
// RebindViolationTests.swift
// ARO Runtime - Immutable rebind must not be fatal (GitLab #495)
// ============================================================
//
// `RuntimeContext.bindTyped` used to fatalError on an immutable rebind,
// taking the whole process down (REPL kernels died with SIGTRAP). The
// contract now: the write is refused, the existing value stays, and the
// violation is recorded for the executor to throw as a statement error.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Rebind violation (GitLab #495)")
struct RebindViolationTests {

    @Test("Immutable rebind is refused and recorded, not fatal")
    func rebindRefusedAndRecorded() {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("v", value: 5)
        context.bind("v", value: 6)  // used to fatalError — must survive

        // The write was refused: the first binding stays.
        #expect(context.resolveAny("v") as? Int == 5)

        let violation = context.takeRebindViolation()
        #expect(violation != nil)
        #expect(violation?.message.contains("Cannot rebind immutable variable 'v'") == true)
        #expect(violation?.message.contains("Variables in ARO are immutable") == true)
        #expect(violation?.message.contains("Please report this as a compiler bug") == true)

        // The slot is consumed on take.
        #expect(context.takeRebindViolation() == nil)
    }

    @Test("First violation wins when several are recorded")
    func firstViolationWins() {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: 1)
        context.bind("b", value: 1)
        context.bind("a", value: 2)
        context.bind("b", value: 2)
        let violation = context.takeRebindViolation()
        #expect(violation?.message.contains("'a'") == true)
        #expect(context.takeRebindViolation() == nil)
    }

    @Test("Framework variables, allowRebind, and mutable scopes record nothing")
    func legitimateRebindsRecordNothing() {
        let context = RuntimeContext(featureSetName: "Test")

        // Framework variables (underscore prefix) stay mutable.
        context.bind("_with_", value: 1)
        context.bind("_with_", value: 2)
        #expect(context.resolveAny("_with_") as? Int == 2)

        // Explicit allowRebind (Accept, Update, REQUEST verbs) still works.
        context.bind("a", value: 1)
        context.bind("a", value: 2, allowRebind: true)
        #expect(context.resolveAny("a") as? Int == 2)

        // While-loop bodies enter a mutable scope.
        context.bind("b", value: 1)
        context.enterMutableScope()
        context.bind("b", value: 2)
        context.exitMutableScope()
        #expect(context.resolveAny("b") as? Int == 2)

        #expect(context.takeRebindViolation() == nil)
    }

    @Test("Violation recorded through a statement scope surfaces on the owner")
    func statementScopeRoutesToOwner() {
        let owner = RuntimeContext(featureSetName: "Test")
        owner.bind("v", value: 1)

        // Non-framework binds in a statement scope write through to the
        // owner (ARO-0088 §2) — the refusal must land where the executor's
        // per-statement check looks.
        let scope = owner.createStatementScope()
        scope.bind("v", value: 2)

        #expect(owner.resolveAny("v") as? Int == 1)
        #expect(owner.takeRebindViolation() != nil)
    }
}
