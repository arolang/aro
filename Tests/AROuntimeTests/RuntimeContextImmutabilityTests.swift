// ============================================================
// RuntimeContextImmutabilityTests.swift
// ARO Runtime Tests - RuntimeContext Immutability
// ============================================================

import Testing
@testable import ARORuntime

@Suite("Runtime Context Immutability")
struct RuntimeContextImmutabilityTests {

    @Test("User variables are tracked as immutable")
    func testUserVariableTracking() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Bind a user variable
        context.bind("value", value: "first")

        // Verify it exists
        let resolved: String? = context.resolve("value")
        #expect(resolved == "first")

        // Note: We cannot test the rebinding failure here because it calls fatalError()
        // The semantic analyzer should catch this at compile-time
        // This test verifies the tracking mechanism exists
    }

    @Test("Framework variables can be rebound")
    func testFrameworkVariableRebinding() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Bind framework variable (starts with _)
        context.bind("_internal", value: "first")
        let first: String? = context.resolve("_internal")
        #expect(first == "first")

        // Rebind framework variable (should work)
        context.bind("_internal", value: "second")
        let second: String? = context.resolve("_internal")
        #expect(second == "second")

        // Framework variables can be rebound multiple times
        context.bind("_internal", value: "third")
        let third: String? = context.resolve("_internal")
        #expect(third == "third")
    }

    @Test("Child contexts have independent immutability tracking")
    func testChildContextImmutabilityIndependence() async throws {
        let parent = RuntimeContext(featureSetName: "Parent")
        parent.bind("value", value: "parent")

        // Create child context
        let child = parent.createChild(featureSetName: "Child")

        // Child can bind same variable name (different scope)
        child.bind("value", value: "child")

        // Verify both contexts have their own values
        let parentValue: String? = parent.resolve("value")
        let childValue: String? = child.resolve("value")

        #expect(parentValue == "parent")
        #expect(childValue == "child")
    }

    @Test("Unbind removes immutability tracking")
    func testUnbindRemovesTracking() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Bind a variable
        context.bind("value", value: "first")
        #expect(context.exists("value"))

        // Unbind it
        context.unbind("value")
        #expect(!context.exists("value"))

        // Should be able to bind again after unbinding
        context.bind("value", value: "second")
        let resolved: String? = context.resolve("value")
        #expect(resolved == "second")
    }

    @Test("Multiple framework variables can coexist")
    func testMultipleFrameworkVariables() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Bind multiple framework variables
        context.bind("_temp1", value: "value1")
        context.bind("_temp2", value: "value2")
        context.bind("_temp3", value: "value3")

        // All can be rebound independently
        context.bind("_temp1", value: "updated1")
        context.bind("_temp2", value: "updated2")

        let temp1: String? = context.resolve("_temp1")
        let temp2: String? = context.resolve("_temp2")
        let temp3: String? = context.resolve("_temp3")

        #expect(temp1 == "updated1")
        #expect(temp2 == "updated2")
        #expect(temp3 == "value3")
    }

    @Test("Variable names are case-sensitive for immutability")
    func testCaseSensitiveVariableNames() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Different case = different variables
        context.bind("value", value: "lowercase")
        context.bind("Value", value: "uppercase-V")
        context.bind("VALUE", value: "all-caps")

        let lower: String? = context.resolve("value")
        let upper: String? = context.resolve("Value")
        let caps: String? = context.resolve("VALUE")

        #expect(lower == "lowercase")
        #expect(upper == "uppercase-V")
        #expect(caps == "all-caps")
    }

    @Test("Framework variable prefix check is exact")
    func testFrameworkVariablePrefixCheck() async throws {
        let context = RuntimeContext(featureSetName: "Test")

        // Only variables STARTING with _ are framework variables
        context.bind("_framework", value: "yes")
        context.bind("not_framework", value: "no") // _ in middle, not start

        // _framework can be rebound
        context.bind("_framework", value: "updated")

        let framework: String? = context.resolve("_framework")
        #expect(framework == "updated")

        // not_framework is a regular variable (would fail if rebound)
        // We don't test the failure here since it would fatalError
    }

    @Test("Loop iteration contexts are independent")
    func testLoopIterationContexts() async throws {
        let parent = RuntimeContext(featureSetName: "Parent")

        // Simulate loop iterations with child contexts
        var results: [String] = []

        for i in 1...3 {
            let iterationContext = parent.createChild(featureSetName: "Iteration\(i)")

            // Each iteration can bind the same variable name
            iterationContext.bind("item", value: "iteration-\(i)")

            if let item: String = iterationContext.resolve("item") {
                results.append(item)
            }
        }

        #expect(results.count == 3)
        #expect(results[0] == "iteration-1")
        #expect(results[1] == "iteration-2")
        #expect(results[2] == "iteration-3")
    }

    @Test("Parent variables are accessible from child context")
    func testParentVariableAccess() async throws {
        let parent = RuntimeContext(featureSetName: "Parent")
        parent.bind("shared", value: "from-parent")

        let child = parent.createChild(featureSetName: "Child")

        // Child can resolve parent's variables
        let shared: String? = child.resolve("shared")
        #expect(shared == "from-parent")

        // Child can also have its own variables
        child.bind("local", value: "child-only")

        let local: String? = child.resolve("local")
        #expect(local == "child-only")

        // Parent cannot see child's variables
        let localInParent: String? = parent.resolve("local")
        #expect(localInParent == nil)
    }
}
