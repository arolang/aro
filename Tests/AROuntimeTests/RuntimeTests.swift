// ============================================================
// RuntimeTests.swift
// ARO Runtime - Comprehensive Runtime Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Action Role Tests

@Suite("Action Role Tests")
struct ActionRoleTests {

    @Test("All action roles exist")
    func testActionRolesExist() {
        #expect(ActionRole.request.rawValue == "request")
        #expect(ActionRole.own.rawValue == "own")
        #expect(ActionRole.response.rawValue == "response")
        #expect(ActionRole.export.rawValue == "export")
    }

    @Test("Action role conversion from parser role")
    func testConversionFromParserRole() {
        #expect(ActionRole(from: .request) == .request)
        #expect(ActionRole(from: .own) == .own)
        #expect(ActionRole(from: .response) == .response)
        #expect(ActionRole(from: .export) == .export)
    }

    @Test("Action roles are case iterable")
    func testCaseIterable() {
        #expect(ActionRole.allCases.count == 4)
    }
}

// MARK: - Action Registry Tests

@Suite("Action Registry Tests")
struct ActionRegistryTests {

    @Test("Shared registry exists")
    func testSharedRegistryExists() async {
        let registry = ActionRegistry.shared
        let verbs = await registry.registeredVerbs
        #expect(verbs.isEmpty == false)
    }

    @Test("Built-in verbs are registered")
    func testBuiltInVerbs() async {
        let registry = ActionRegistry.shared

        #expect(await registry.isRegistered("extract"))
        #expect(await registry.isRegistered("compute"))
        #expect(await registry.isRegistered("return"))
        #expect(await registry.isRegistered("publish"))
    }

    @Test("Action lookup returns implementation")
    func testActionLookup() async {
        let registry = ActionRegistry.shared

        let extractAction = await registry.action(for: "extract")
        #expect(extractAction != nil)
    }

    @Test("Unknown action returns nil")
    func testUnknownAction() async {
        let registry = ActionRegistry.shared

        let unknown = await registry.action(for: "nonexistent-action")
        #expect(unknown == nil)
    }

    @Test("Case insensitive lookup")
    func testCaseInsensitiveLookup() async {
        let registry = ActionRegistry.shared

        #expect(await registry.isRegistered("EXTRACT"))
        #expect(await registry.isRegistered("Extract"))
        #expect(await registry.isRegistered("extract"))
    }

    @Test("Registered verbs list")
    func testRegisteredVerbsList() async {
        let registry = ActionRegistry.shared
        let verbs = await registry.registeredVerbs

        #expect(verbs.contains("extract"))
        #expect(verbs.contains("compute"))
        #expect(verbs.contains("return"))
    }

    @Test("Actions grouped by role")
    func testActionsByRole() async {
        let registry = ActionRegistry.shared
        let byRole = await registry.actionsByRole

        #expect(byRole[.request]?.isEmpty == false)
        #expect(byRole[.own]?.isEmpty == false)
        #expect(byRole[.response]?.isEmpty == false)
        #expect(byRole[.export]?.isEmpty == false)
    }
}

// MARK: - Runtime Context Tests

@Suite("Runtime Context Tests")
struct RuntimeContextTests {

    @Test("Context creation with name")
    func testContextCreation() {
        let context = RuntimeContext(featureSetName: "Test")

        #expect(context.featureSetName == "Test")
        #expect(context.executionId.isEmpty == false)
    }

    @Test("Variable binding and resolution")
    func testVariableBinding() {
        let context = RuntimeContext(featureSetName: "Test")

        context.bind("user", value: "John")

        let value: String? = context.resolve("user")
        #expect(value == "John")
    }

    @Test("Variable exists check")
    func testVariableExists() {
        let context = RuntimeContext(featureSetName: "Test")

        context.bind("user", value: "John")

        #expect(context.exists("user") == true)
        #expect(context.exists("other") == false)
    }

    @Test("Variable names list")
    func testVariableNames() {
        let context = RuntimeContext(featureSetName: "Test")

        context.bind("a", value: 1)
        context.bind("b", value: 2)

        let names = context.variableNames
        #expect(names.contains("a"))
        #expect(names.contains("b"))
    }

    @Test("Resolve any value")
    func testResolveAny() {
        let context = RuntimeContext(featureSetName: "Test")

        context.bind("value", value: 42)

        let result = context.resolveAny("value")
        #expect(result != nil)
    }

    @Test("Child context inherits variables")
    func testChildContextInheritance() {
        let parent = RuntimeContext(featureSetName: "Parent")
        parent.bind("parentVar", value: "parentValue")

        let child = parent.createChild(featureSetName: "Child")

        let value: String? = child.resolve("parentVar")
        #expect(value == "parentValue")
    }

    @Test("Child context overrides parent variables")
    func testChildContextOverride() {
        let parent = RuntimeContext(featureSetName: "Parent")
        parent.bind("shared", value: "parent")

        let child = parent.createChild(featureSetName: "Child") as! RuntimeContext
        child.bind("shared", value: "child")

        let childValue: String? = child.resolve("shared")
        #expect(childValue == "child")
    }

    @Test("Bind all convenience method")
    func testBindAll() {
        let context = RuntimeContext(featureSetName: "Test")

        context.bindAll([
            "a": 1,
            "b": "two",
            "c": true
        ])

        #expect(context.exists("a"))
        #expect(context.exists("b"))
        #expect(context.exists("c"))
    }

    @Test("Static with convenience method")
    func testStaticWith() {
        let context = RuntimeContext.with(
            featureSetName: "Test",
            initialBindings: ["x": 10, "y": 20]
        )

        let x: Int? = context.resolve("x")
        let y: Int? = context.resolve("y")
        #expect(x == 10)
        #expect(y == 20)
    }

    @Test("Service registration and lookup")
    func testServiceRegistration() {
        let context = RuntimeContext(featureSetName: "Test")

        let service = TestService()
        context.register(service)

        let retrieved = context.service(TestService.self)
        #expect(retrieved != nil)
    }

    @Test("Response management")
    func testResponseManagement() {
        let context = RuntimeContext(featureSetName: "Test")

        let response = Response(status: "OK")
        context.setResponse(response)

        let retrieved = context.getResponse()
        #expect(retrieved?.status == "OK")
    }
}

// Helper for testing
private final class TestService: Sendable {}

// MARK: - Event Bus Tests

@Suite("Event Bus Tests")
struct EventBusTests {

    @Test("Shared event bus exists")
    func testSharedEventBus() {
        let bus = EventBus.shared
        #expect(bus.subscriptionCount >= 0)
    }

    @Test("Event bus subscription count")
    func testSubscriptionCount() {
        let bus = EventBus()
        #expect(bus.subscriptionCount == 0)

        bus.subscribe(to: "test") { _ in }
        #expect(bus.subscriptionCount == 1)
    }

    @Test("Unsubscribe removes subscription")
    func testUnsubscribe() {
        let bus = EventBus()

        let id = bus.subscribe(to: "test") { _ in }
        #expect(bus.subscriptionCount == 1)

        bus.unsubscribe(id)
        #expect(bus.subscriptionCount == 0)
    }

    @Test("Unsubscribe all")
    func testUnsubscribeAll() {
        let bus = EventBus()

        bus.subscribe(to: "test1") { _ in }
        bus.subscribe(to: "test2") { _ in }
        #expect(bus.subscriptionCount == 2)

        bus.unsubscribeAll()
        #expect(bus.subscriptionCount == 0)
    }
}

// MARK: - Action Descriptor Tests

@Suite("Action Descriptor Tests")
struct ActionDescriptorTests {

    @Test("ResultDescriptor creation")
    func testResultDescriptorCreation() {
        let span = SourceSpan(at: SourceLocation())
        let descriptor = ResultDescriptor(
            base: "user",
            specifiers: ["id", "name"],
            span: span
        )

        #expect(descriptor.base == "user")
        #expect(descriptor.specifiers == ["id", "name"])
    }

    @Test("ObjectDescriptor creation")
    func testObjectDescriptorCreation() {
        let span = SourceSpan(at: SourceLocation())
        let descriptor = ObjectDescriptor(
            preposition: .from,
            base: "request",
            specifiers: ["body"],
            span: span
        )

        #expect(descriptor.preposition == .from)
        #expect(descriptor.base == "request")
        #expect(descriptor.specifiers == ["body"])
    }

    @Test("ObjectDescriptor external source check")
    func testExternalSourceCheck() {
        let span = SourceSpan(at: SourceLocation())
        let fromDescriptor = ObjectDescriptor(
            preposition: .from,
            base: "request",
            specifiers: [],
            span: span
        )
        #expect(fromDescriptor.isExternalReference == true)

        let forDescriptor = ObjectDescriptor(
            preposition: .for,
            base: "input",
            specifiers: [],
            span: span
        )
        #expect(forDescriptor.isExternalReference == false)
    }

    @Test("ResultDescriptor full name")
    func testResultDescriptorFullName() {
        let span = SourceSpan(at: SourceLocation())
        let simple = ResultDescriptor(base: "user", specifiers: [], span: span)
        #expect(simple.fullName == "user")

        let qualified = ResultDescriptor(base: "user", specifiers: ["id"], span: span)
        #expect(qualified.fullName == "user: id")
    }

    @Test("ObjectDescriptor full name")
    func testObjectDescriptorFullName() {
        let span = SourceSpan(at: SourceLocation())
        let simple = ObjectDescriptor(preposition: .from, base: "request", specifiers: [], span: span)
        #expect(simple.fullName == "request")

        let qualified = ObjectDescriptor(preposition: .from, base: "request", specifiers: ["body"], span: span)
        #expect(qualified.fullName == "request: body")
    }

    @Test("ObjectDescriptor key path")
    func testObjectDescriptorKeyPath() {
        let span = SourceSpan(at: SourceLocation())
        let simple = ObjectDescriptor(preposition: .from, base: "request", specifiers: [], span: span)
        #expect(simple.keyPath == "request")

        let nested = ObjectDescriptor(preposition: .from, base: "request", specifiers: ["body", "user"], span: span)
        #expect(nested.keyPath == "request.body.user")
    }
}

// MARK: - Action Error Tests

@Suite("Action Error Tests")
struct ActionErrorTests {

    @Test("Unknown action error")
    func testUnknownActionError() {
        let error = ActionError.unknownAction("nonexistent")

        #expect(error.localizedDescription.contains("nonexistent"))
    }

    @Test("Invalid preposition error")
    func testInvalidPrepositionError() {
        let error = ActionError.invalidPreposition(
            action: "Extract",
            received: .for,
            expected: [.from]
        )

        let description = error.localizedDescription
        #expect(description.contains("Extract"))
        #expect(description.contains("for"))
    }

    @Test("Undefined variable error")
    func testUndefinedVariableError() {
        let error = ActionError.undefinedVariable("user")

        #expect(error.localizedDescription.contains("user"))
    }

    @Test("Type mismatch error")
    func testTypeMismatchError() {
        let error = ActionError.typeMismatch(
            expected: "Int",
            actual: "String"
        )

        let description = error.localizedDescription
        #expect(description.contains("Int"))
        #expect(description.contains("String"))
    }

    @Test("Runtime error")
    func testRuntimeError() {
        let error = ActionError.runtimeError("Something failed")

        #expect(error.localizedDescription.contains("Something failed"))
    }

    @Test("Validation failed error")
    func testValidationFailedError() {
        let error = ActionError.validationFailed("Invalid input")

        #expect(error.localizedDescription.contains("Validation failed"))
    }

    @Test("Missing service error")
    func testMissingServiceError() {
        let error = ActionError.missingService("HTTPClient")

        #expect(error.localizedDescription.contains("HTTPClient"))
    }

    @Test("Undefined repository error")
    func testUndefinedRepositoryError() {
        let error = ActionError.undefinedRepository("user-repo")

        #expect(error.localizedDescription.contains("user-repo"))
    }
}

// MARK: - Response Tests

@Suite("Response Tests")
struct ResponseTests {

    @Test("Response creation")
    func testResponseCreation() {
        let response = Response(status: "OK")

        #expect(response.status == "OK")
    }

    @Test("Response with reason")
    func testResponseWithReason() {
        let response = Response(status: "Error", reason: "Not found")

        #expect(response.status == "Error")
        #expect(response.reason == "Not found")
    }

    @Test("Response OK helper")
    func testResponseOK() {
        let response = Response.ok()

        #expect(response.status == "OK")
    }

    @Test("Response error helper")
    func testResponseError() {
        let response = Response.error("Something went wrong")

        #expect(response.status == "Error")
        #expect(response.reason == "Something went wrong")
    }
}

// MARK: - AnySendable Tests

@Suite("AnySendable Tests")
struct AnySendableTests {

    @Test("AnySendable wraps values")
    func testAnySendableWraps() {
        let wrapped = AnySendable(42)
        let value: Int? = wrapped.get()

        #expect(value == 42)
    }

    @Test("AnySendable equality")
    func testAnySendableEquality() {
        let a = AnySendable(42)
        let b = AnySendable(42)
        let c = AnySendable(0)

        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - Statement Descriptor Tests

@Suite("Statement Descriptor Tests")
struct StatementDescriptorTests {

    @Test("Statement descriptor creation")
    func testStatementDescriptorCreation() {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "user", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "request", specifiers: [], span: span)

        let descriptor = StatementDescriptor(
            verb: "Extract",
            role: .request,
            result: result,
            object: object
        )

        #expect(descriptor.verb == "Extract")
        #expect(descriptor.role == .request)
    }
}
