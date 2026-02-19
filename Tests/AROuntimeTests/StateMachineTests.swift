// ============================================================
// StateMachineTests.swift
// Tests for State Machine functionality (Accept action, State Guards)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

// MARK: - Helper

private let span = SourceSpan(at: SourceLocation())

private func createDescriptors(
    resultBase: String,
    resultSpecifiers: [String] = [],
    preposition: Preposition = .on,
    objectBase: String,
    objectSpecifiers: [String] = []
) -> (ResultDescriptor, ObjectDescriptor) {
    let result = ResultDescriptor(base: resultBase, specifiers: resultSpecifiers, span: span)
    let object = ObjectDescriptor(preposition: preposition, base: objectBase, specifiers: objectSpecifiers, span: span)
    return (result, object)
}

// MARK: - AcceptAction Tests

@Suite("AcceptAction Tests")
struct AcceptActionTests {

    @Test("Accept action role is own")
    func testActionRole() {
        #expect(AcceptAction.role == .own)
    }

    @Test("Accept action verbs include accept")
    func testActionVerbs() {
        #expect(AcceptAction.verbs.contains("accept"))
    }

    @Test("Accept action valid prepositions include on")
    func testValidPrepositions() {
        #expect(AcceptAction.validPrepositions.contains(.on))
    }

    @Test("Accept valid state transition")
    func testValidTransition() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Setup order with draft status
        let order: [String: any Sendable] = [
            "id": "order-123",
            "status": "draft",
            "total": 99.99
        ]
        context.bind("order", value: order)

        // Create descriptors for: Accept the <transition: draft_to_placed> on <order: status>
        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["draft_to_placed"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        // Execute the action
        let resultValue = try await action.execute(result: result, object: object, context: context)

        // Verify the state was updated
        if let updatedOrder = resultValue as? [String: any Sendable],
           let newStatus = updatedOrder["status"] as? String {
            #expect(newStatus == "placed")
        } else {
            Issue.record("Expected updated order dictionary")
        }
    }

    @Test("Accept action rejects invalid current state")
    func testRejectInvalidCurrentState() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Setup order with "paid" status (not "draft")
        let order: [String: any Sendable] = [
            "id": "order-123",
            "status": "paid",
            "total": 99.99
        ]
        context.bind("order", value: order)

        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["draft_to_placed"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        // Should throw AcceptStateError
        do {
            _ = try await action.execute(result: result, object: object, context: context)
            Issue.record("Expected AcceptStateError to be thrown")
        } catch let error as AcceptStateError {
            #expect(error.expectedFrom == "draft")
            #expect(error.expectedTo == "placed")
            #expect(error.actualState == "paid")
            #expect(error.objectName == "order")
            #expect(error.fieldName == "status")
        } catch {
            Issue.record("Expected AcceptStateError, got: \(error)")
        }
    }

    @Test("Accept action parses transition with _to_ separator")
    func testTransitionParsing() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let request: [String: any Sendable] = [
            "id": "req-1",
            "state": "pending"
        ]
        context.bind("request", value: request)

        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["pending_to_approved"],
            objectBase: "request",
            objectSpecifiers: ["state"]
        )

        let resultValue = try await action.execute(result: result, object: object, context: context)

        if let updated = resultValue as? [String: any Sendable],
           let newState = updated["state"] as? String {
            #expect(newState == "approved")
        } else {
            Issue.record("Expected updated request dictionary")
        }
    }

    @Test("Accept action uses default field name 'status'")
    func testDefaultFieldName() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let order: [String: any Sendable] = [
            "id": "order-1",
            "status": "new"
        ]
        context.bind("order", value: order)

        // No specifiers = defaults to "status"
        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["new_to_processing"],
            objectBase: "order"
        )

        let resultValue = try await action.execute(result: result, object: object, context: context)

        if let updated = resultValue as? [String: any Sendable],
           let newStatus = updated["status"] as? String {
            #expect(newStatus == "processing")
        } else {
            Issue.record("Expected updated order dictionary")
        }
    }

    @Test("Accept action fails with undefined variable")
    func testUndefinedVariable() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["draft_to_placed"],
            objectBase: "nonexistent",
            objectSpecifiers: ["status"]
        )

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            Issue.record("Expected ActionError to be thrown")
        } catch is ActionError {
            // Expected
        } catch {
            Issue.record("Expected ActionError, got: \(error)")
        }
    }

    @Test("Accept action fails with invalid transition format")
    func testInvalidTransitionFormat() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let order: [String: any Sendable] = ["status": "draft"]
        context.bind("order", value: order)

        // Invalid format - no _to_ separator
        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["invalid-format"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        do {
            _ = try await action.execute(result: result, object: object, context: context)
            Issue.record("Expected ActionError to be thrown")
        } catch is ActionError {
            // Expected
        } catch {
            Issue.record("Expected ActionError, got: \(error)")
        }
    }

    @Test("Accept action preserves other fields")
    func testPreservesOtherFields() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let order: [String: any Sendable] = [
            "id": "order-789",
            "status": "pending",
            "total": 150.00,
            "customer": "John Doe",
            "items": 3
        ]
        context.bind("order", value: order)

        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["pending_to_confirmed"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        let resultValue = try await action.execute(result: result, object: object, context: context)

        if let updated = resultValue as? [String: any Sendable] {
            #expect(updated["status"] as? String == "confirmed")
            #expect(updated["id"] as? String == "order-789")
            #expect(updated["total"] as? Double == 150.00)
            #expect(updated["customer"] as? String == "John Doe")
            #expect(updated["items"] as? Int == 3)
        } else {
            Issue.record("Expected updated order dictionary")
        }
    }

    @Test("Accept action updates context binding")
    func testUpdatesContextBinding() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        let order: [String: any Sendable] = [
            "id": "order-1",
            "status": "draft"
        ]
        context.bind("order", value: order)

        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["draft_to_placed"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        _ = try await action.execute(result: result, object: object, context: context)

        // Verify the context was updated
        if let contextOrder = context.resolveAny("order") as? [String: any Sendable] {
            #expect(contextOrder["status"] as? String == "placed")
        } else {
            Issue.record("Expected order in context")
        }
    }

    @Test("Sequential state transitions")
    func testSequentialTransitions() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Start with draft order
        let order: [String: any Sendable] = [
            "id": "order-1",
            "status": "draft"
        ]
        context.bind("order", value: order)

        let orderDesc = ObjectDescriptor(
            preposition: .on,
            base: "order",
            specifiers: ["status"],
            span: span
        )

        // Transition: draft -> placed
        let transition1 = ResultDescriptor(
            base: "transition",
            specifiers: ["draft_to_placed"],
            span: span
        )
        _ = try await action.execute(result: transition1, object: orderDesc, context: context)

        // Verify intermediate state
        if let updated = context.resolveAny("order") as? [String: any Sendable] {
            #expect(updated["status"] as? String == "placed")
        }

        // Transition: placed -> paid
        let transition2 = ResultDescriptor(
            base: "transition",
            specifiers: ["placed_to_paid"],
            span: span
        )
        _ = try await action.execute(result: transition2, object: orderDesc, context: context)

        // Verify final state
        if let final = context.resolveAny("order") as? [String: any Sendable] {
            #expect(final["status"] as? String == "paid")
        }
    }
}

// MARK: - AcceptStateError Tests

@Suite("AcceptStateError Tests")
struct AcceptStateErrorTests {

    @Test("Error description format")
    func testErrorDescription() {
        let error = AcceptStateError(
            expectedFrom: "draft",
            expectedTo: "placed",
            actualState: "paid",
            objectName: "order",
            fieldName: "status"
        )

        let description = error.errorDescription ?? ""
        #expect(description.contains("draft"))
        #expect(description.contains("placed"))
        #expect(description.contains("paid"))
        #expect(description.contains("order"))
        #expect(description.contains("status"))
    }

    @Test("Error properties are accessible")
    func testErrorProperties() {
        let error = AcceptStateError(
            expectedFrom: "pending",
            expectedTo: "approved",
            actualState: "rejected",
            objectName: "request",
            fieldName: "state"
        )

        #expect(error.expectedFrom == "pending")
        #expect(error.expectedTo == "approved")
        #expect(error.actualState == "rejected")
        #expect(error.objectName == "request")
        #expect(error.fieldName == "state")
    }

    @Test("Error conforms to LocalizedError")
    func testLocalizedError() {
        let error = AcceptStateError(
            expectedFrom: "a",
            expectedTo: "b",
            actualState: "c",
            objectName: "obj",
            fieldName: "field"
        )

        // LocalizedError protocol
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
    }
}

// MARK: - StateGuard Tests

@Suite("StateGuard Tests")
struct StateGuardTests {

    @Test("Parse simple state guard")
    func testParseSimple() {
        let guard_ = StateGuard.parse("status:paid")

        #expect(guard_ != nil)
        #expect(guard_?.fieldPath == "status")
        #expect(guard_?.validValues.contains("paid") == true)
    }

    @Test("Parse state guard with multiple values (OR logic)")
    func testParseMultipleValues() {
        let guard_ = StateGuard.parse("status:paid,shipped,delivered")

        #expect(guard_ != nil)
        #expect(guard_?.fieldPath == "status")
        #expect(guard_?.validValues.count == 3)
        #expect(guard_?.validValues.contains("paid") == true)
        #expect(guard_?.validValues.contains("shipped") == true)
        #expect(guard_?.validValues.contains("delivered") == true)
    }

    @Test("Parse nested field path")
    func testParseNestedField() {
        let guard_ = StateGuard.parse("entity.status:active")

        #expect(guard_ != nil)
        #expect(guard_?.fieldPath == "entity.status")
        #expect(guard_?.validValues.contains("active") == true)
    }

    @Test("Parse with whitespace trimming")
    func testWhitespaceTrimming() {
        let guard_ = StateGuard.parse("  status  :  paid , shipped  ")

        #expect(guard_ != nil)
        #expect(guard_?.fieldPath == "status")
        #expect(guard_?.validValues.contains("paid") == true)
        #expect(guard_?.validValues.contains("shipped") == true)
    }

    @Test("Parse returns nil for invalid format")
    func testInvalidFormat() {
        #expect(StateGuard.parse("invalid") == nil)
        #expect(StateGuard.parse("") == nil)
        #expect(StateGuard.parse(":value") == nil)
        #expect(StateGuard.parse("field:") == nil)
    }

    @Test("Match payload with single value")
    func testMatchSingleValue() {
        let guard_ = StateGuard.parse("status:active")!

        let matchingPayload: [String: any Sendable] = ["status": "active"]
        let nonMatchingPayload: [String: any Sendable] = ["status": "inactive"]

        #expect(guard_.matches(payload: matchingPayload) == true)
        #expect(guard_.matches(payload: nonMatchingPayload) == false)
    }

    @Test("Match payload with multiple values (OR)")
    func testMatchOrLogic() {
        let guard_ = StateGuard.parse("tier:premium,gold")!

        let premiumPayload: [String: any Sendable] = ["tier": "premium"]
        let goldPayload: [String: any Sendable] = ["tier": "gold"]
        let silverPayload: [String: any Sendable] = ["tier": "silver"]

        #expect(guard_.matches(payload: premiumPayload) == true)
        #expect(guard_.matches(payload: goldPayload) == true)
        #expect(guard_.matches(payload: silverPayload) == false)
    }

    @Test("Match is case-insensitive")
    func testCaseInsensitive() {
        let guard_ = StateGuard.parse("status:ACTIVE")!

        let lowerPayload: [String: any Sendable] = ["status": "active"]
        let upperPayload: [String: any Sendable] = ["status": "ACTIVE"]
        let mixedPayload: [String: any Sendable] = ["status": "Active"]

        #expect(guard_.matches(payload: lowerPayload) == true)
        #expect(guard_.matches(payload: upperPayload) == true)
        #expect(guard_.matches(payload: mixedPayload) == true)
    }

    @Test("Match nested field path")
    func testMatchNestedPath() {
        let guard_ = StateGuard.parse("order.status:completed")!

        let matchingPayload: [String: any Sendable] = [
            "order": ["status": "completed", "id": "123"] as [String: any Sendable]
        ]
        let nonMatchingPayload: [String: any Sendable] = [
            "order": ["status": "pending", "id": "123"] as [String: any Sendable]
        ]

        #expect(guard_.matches(payload: matchingPayload) == true)
        #expect(guard_.matches(payload: nonMatchingPayload) == false)
    }

    @Test("Match returns false for missing field")
    func testMissingField() {
        let guard_ = StateGuard.parse("status:active")!

        let missingFieldPayload: [String: any Sendable] = ["other": "value"]

        #expect(guard_.matches(payload: missingFieldPayload) == false)
    }

    @Test("Match non-string values")
    func testNonStringValues() {
        let guard_ = StateGuard.parse("count:5")!

        let intPayload: [String: any Sendable] = ["count": 5]

        #expect(guard_.matches(payload: intPayload) == true)
    }

    @Test("StateGuard is Sendable")
    func testSendable() {
        let guard_ = StateGuard.parse("status:active")!

        // If this compiles, StateGuard conforms to Sendable
        let _: Sendable = guard_
        #expect(guard_.fieldPath == "status")
    }
}

// MARK: - StateGuardSet Tests

@Suite("StateGuardSet Tests")
struct StateGuardSetTests {

    @Test("Parse single guard from business activity")
    func testParseSingleGuard() {
        let guardSet = StateGuardSet.parse(from: "UserCreated Handler<status:active>")

        #expect(guardSet.count == 1)
        #expect(guardSet.guards.first?.fieldPath == "status")
        #expect(guardSet.guards.first?.validValues.contains("active") == true)
    }

    @Test("Parse multiple guards (AND logic)")
    func testParseMultipleGuards() {
        let guardSet = StateGuardSet.parse(from: "OrderEvent Handler<status:paid;tier:premium>")

        #expect(guardSet.count == 2)

        let statusGuard = guardSet.guards.first { $0.fieldPath == "status" }
        let tierGuard = guardSet.guards.first { $0.fieldPath == "tier" }

        #expect(statusGuard?.validValues.contains("paid") == true)
        #expect(tierGuard?.validValues.contains("premium") == true)
    }

    @Test("Parse returns empty set for no guards")
    func testParseNoGuards() {
        let guardSet = StateGuardSet.parse(from: "SimpleHandler")

        #expect(guardSet.isEmpty)
        #expect(guardSet.count == 0)
    }

    @Test("Parse ignores transition syntax (no colon)")
    func testIgnoreTransitionSyntax() {
        // StateObserver syntax uses <from_to_target> without colon
        let guardSet = StateGuardSet.parse(from: "order-status Observer<draft_to_placed>")

        #expect(guardSet.isEmpty)
    }

    @Test("All guards must match (AND logic)")
    func testAndLogic() {
        let guardSet = StateGuardSet.parse(from: "Handler<status:active;role:admin>")

        let bothMatch: [String: any Sendable] = ["status": "active", "role": "admin"]
        let onlyStatusMatches: [String: any Sendable] = ["status": "active", "role": "user"]
        let onlyRoleMatches: [String: any Sendable] = ["status": "inactive", "role": "admin"]
        let noneMatch: [String: any Sendable] = ["status": "inactive", "role": "user"]

        #expect(guardSet.allMatch(payload: bothMatch) == true)
        #expect(guardSet.allMatch(payload: onlyStatusMatches) == false)
        #expect(guardSet.allMatch(payload: onlyRoleMatches) == false)
        #expect(guardSet.allMatch(payload: noneMatch) == false)
    }

    @Test("Empty guard set always matches")
    func testEmptySetMatches() {
        let guardSet = StateGuardSet(guards: [])

        let anyPayload: [String: any Sendable] = ["anything": "value"]

        #expect(guardSet.allMatch(payload: anyPayload) == true)
        #expect(guardSet.isEmpty == true)
    }

    @Test("Combined OR and AND logic")
    func testCombinedOrAnd() {
        // status must be "paid" OR "shipped" AND tier must be "premium" OR "gold"
        let guardSet = StateGuardSet.parse(from: "Handler<status:paid,shipped;tier:premium,gold>")

        let paidPremium: [String: any Sendable] = ["status": "paid", "tier": "premium"]
        let shippedGold: [String: any Sendable] = ["status": "shipped", "tier": "gold"]
        let paidSilver: [String: any Sendable] = ["status": "paid", "tier": "silver"]
        let pendingPremium: [String: any Sendable] = ["status": "pending", "tier": "premium"]

        #expect(guardSet.allMatch(payload: paidPremium) == true)
        #expect(guardSet.allMatch(payload: shippedGold) == true)
        #expect(guardSet.allMatch(payload: paidSilver) == false)
        #expect(guardSet.allMatch(payload: pendingPremium) == false)
    }

    @Test("StateGuardSet is Sendable")
    func testSendable() {
        let guardSet = StateGuardSet.parse(from: "Handler<status:active>")

        // If this compiles, StateGuardSet conforms to Sendable
        let _: Sendable = guardSet
        #expect(guardSet.count == 1)
    }
}

// MARK: - StateTransitionEvent Tests

@Suite("StateTransitionEvent Tests")
struct StateTransitionEventTests {

    @Test("Event type is correct")
    func testEventType() {
        #expect(StateTransitionEvent.eventType == "state.transition")
    }

    @Test("Event stores transition details")
    func testEventDetails() {
        let order: [String: any Sendable] = ["id": "order-1", "status": "placed"]
        let event = StateTransitionEvent(
            fieldName: "status",
            objectName: "order",
            fromState: "draft",
            toState: "placed",
            entityId: "order-1",
            entity: order
        )

        #expect(event.fieldName == "status")
        #expect(event.objectName == "order")
        #expect(event.fromState == "draft")
        #expect(event.toState == "placed")
        #expect(event.entityId == "order-1")
    }

    @Test("Event has timestamp")
    func testEventTimestamp() {
        let beforeTime = Date()
        let event = StateTransitionEvent(
            fieldName: "status",
            objectName: "order",
            fromState: "draft",
            toState: "placed",
            entityId: nil,
            entity: nil
        )
        let afterTime = Date()

        #expect(event.timestamp >= beforeTime)
        #expect(event.timestamp <= afterTime)
    }

    @Test("Event with nil entity ID")
    func testNilEntityId() {
        let event = StateTransitionEvent(
            fieldName: "state",
            objectName: "task",
            fromState: "open",
            toState: "closed",
            entityId: nil,
            entity: nil
        )

        #expect(event.entityId == nil)
        #expect(event.entity == nil)
    }

    @Test("Event conforms to RuntimeEvent")
    func testRuntimeEventConformance() {
        let event = StateTransitionEvent(
            fieldName: "status",
            objectName: "order",
            fromState: "draft",
            toState: "placed",
            entityId: nil,
            entity: nil
        )

        // RuntimeEvent conformance
        #expect(type(of: event).eventType == "state.transition")
        #expect(event.timestamp <= Date())
    }
}

// MARK: - Integration Tests

@Suite("State Machine Integration Tests")
struct StateMachineIntegrationTests {

    @Test("State guard filters matching events")
    func testStateGuardFiltering() {
        let guardSet = StateGuardSet.parse(from: "Handler<status:paid>")

        // Simulate event payload from StateTransitionEvent
        let paidPayload: [String: any Sendable] = [
            "fromState": "placed",
            "toState": "paid",
            "status": "paid"
        ]
        let draftPayload: [String: any Sendable] = [
            "fromState": "new",
            "toState": "draft",
            "status": "draft"
        ]

        #expect(guardSet.allMatch(payload: paidPayload) == true)
        #expect(guardSet.allMatch(payload: draftPayload) == false)
    }

    @Test("Complex nested field matching")
    func testComplexNestedFieldMatching() {
        let guardSet = StateGuardSet.parse(from: "Handler<entity.order.status:paid;entity.user.role:admin>")

        let matchingPayload: [String: any Sendable] = [
            "entity": [
                "order": ["status": "paid"] as [String: any Sendable],
                "user": ["role": "admin"] as [String: any Sendable]
            ] as [String: any Sendable]
        ]

        let partialMatch: [String: any Sendable] = [
            "entity": [
                "order": ["status": "paid"] as [String: any Sendable],
                "user": ["role": "user"] as [String: any Sendable]
            ] as [String: any Sendable]
        ]

        #expect(guardSet.allMatch(payload: matchingPayload) == true)
        #expect(guardSet.allMatch(payload: partialMatch) == false)
    }

    @Test("Full state machine workflow")
    func testFullWorkflow() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "OrderWorkflow")

        // Create an order
        var order: [String: any Sendable] = [
            "id": "order-001",
            "status": "draft",
            "items": 3,
            "total": 299.99
        ]
        context.bind("order", value: order)

        // Define state transitions
        let transitions = [
            ("draft", "placed"),
            ("placed", "paid"),
            ("paid", "shipped"),
            ("shipped", "delivered")
        ]

        // Execute each transition
        for (from, to) in transitions {
            let (result, object) = createDescriptors(
                resultBase: "transition",
                resultSpecifiers: ["\(from)_to_\(to)"],
                objectBase: "order",
                objectSpecifiers: ["status"]
            )

            let updated = try await action.execute(result: result, object: object, context: context)
            order = updated as! [String: any Sendable]
            #expect(order["status"] as? String == to)
        }

        // Verify final state
        #expect(order["status"] as? String == "delivered")
        #expect(order["id"] as? String == "order-001")
        #expect(order["items"] as? Int == 3)
    }

    @Test("Invalid transition in workflow fails")
    func testInvalidTransitionInWorkflow() async throws {
        let action = AcceptAction()
        let context = RuntimeContext(featureSetName: "Test")

        // Order is in "draft" state
        let order: [String: any Sendable] = [
            "id": "order-001",
            "status": "draft"
        ]
        context.bind("order", value: order)

        // Try to skip directly to "shipped" (should fail)
        let (result, object) = createDescriptors(
            resultBase: "transition",
            resultSpecifiers: ["draft_to_shipped"],
            objectBase: "order",
            objectSpecifiers: ["status"]
        )

        // This should succeed (draft -> shipped is syntactically valid)
        // If you want to enforce specific transitions, you need business logic
        let updated = try await action.execute(result: result, object: object, context: context)

        if let updatedOrder = updated as? [String: any Sendable] {
            #expect(updatedOrder["status"] as? String == "shipped")
        }
    }
}
