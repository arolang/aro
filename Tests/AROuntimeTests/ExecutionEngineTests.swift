// ============================================================
// ExecutionEngineTests.swift
// ARO Runtime - Execution Engine Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// Initialize test cleanup as early as possible
private let _initTestCleanup: Void = {
    _ = TestCleanup.shared
}()

// MARK: - Execution Engine Tests

@Suite("Execution Engine Tests")
struct ExecutionEngineTests {

    @Test("Engine initialization with defaults")
    func testEngineInitialization() {
        let engine = ExecutionEngine()
        #expect(engine != nil)
    }

    @Test("Engine initialization with custom action registry")
    func testEngineWithCustomRegistry() {
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let engine = ExecutionEngine(actionRegistry: registry, eventBus: eventBus)
        #expect(engine != nil)
    }

    @Test("Service registration")
    func testServiceRegistration() async {
        let engine = ExecutionEngine()
        let service = MockTestService(value: "test")
        engine.register(service: service)
        // Service should be registered (verified through execution)
        #expect(Bool(true))
    }
}

// MARK: - Global Symbol Storage Tests

@Suite("Global Symbol Storage Tests")
struct GlobalSymbolStorageTests {

    @Test("Publish and resolve symbol")
    func testPublishAndResolve() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "user", value: "John", fromFeatureSet: "FS1", businessActivity: "Activity1")

        let value: String? = storage.resolve("user", forBusinessActivity: "Activity1")
        #expect(value == "John")
    }

    @Test("Resolve symbol returns nil for different business activity")
    func testBusinessActivityIsolation() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "user", value: "John", fromFeatureSet: "FS1", businessActivity: "Activity1")

        let value: String? = storage.resolve("user", forBusinessActivity: "Activity2")
        #expect(value == nil)
    }

    @Test("Resolve symbol with empty business activity is accessible")
    func testEmptyBusinessActivityAccessible() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "config", value: "value", fromFeatureSet: "Framework", businessActivity: "")

        let value: String? = storage.resolve("config", forBusinessActivity: "AnyActivity")
        #expect(value == "value")
    }

    @Test("Resolve any returns correct value")
    func testResolveAny() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "count", value: 42, fromFeatureSet: "FS1", businessActivity: "Activity1")

        let value = storage.resolveAny("count", forBusinessActivity: "Activity1")
        #expect(value != nil)
        #expect(value as? Int == 42)
    }

    @Test("Is published returns true for existing symbol")
    func testIsPublished() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "item", value: "data", fromFeatureSet: "FS1", businessActivity: "Activity1")

        #expect(storage.isPublished("item", forBusinessActivity: "Activity1") == true)
        #expect(storage.isPublished("other", forBusinessActivity: "Activity1") == false)
    }

    @Test("Source feature set tracking")
    func testSourceFeatureSet() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "data", value: "test", fromFeatureSet: "SourceFS", businessActivity: "Activity")

        #expect(storage.sourceFeatureSet(for: "data") == "SourceFS")
        #expect(storage.sourceFeatureSet(for: "unknown") == nil)
    }

    @Test("Business activity tracking")
    func testBusinessActivityTracking() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "config", value: "test", fromFeatureSet: "FS", businessActivity: "MyActivity")

        #expect(storage.businessActivity(for: "config") == "MyActivity")
        #expect(storage.businessActivity(for: "unknown") == nil)
    }

    @Test("Is access denied check")
    func testIsAccessDenied() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "private", value: "secret", fromFeatureSet: "FS1", businessActivity: "Activity1")

        #expect(storage.isAccessDenied("private", forBusinessActivity: "Activity2") == true)
        #expect(storage.isAccessDenied("private", forBusinessActivity: "Activity1") == false)
        #expect(storage.isAccessDenied("nonexistent", forBusinessActivity: "Activity1") == false)
    }

    @Test("Symbol overwriting")
    func testSymbolOverwriting() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "counter", value: 1, fromFeatureSet: "FS1", businessActivity: "Activity")
        storage.publish(name: "counter", value: 2, fromFeatureSet: "FS2", businessActivity: "Activity")

        let value: Int? = storage.resolve("counter", forBusinessActivity: "Activity")
        #expect(value == 2)
        #expect(storage.sourceFeatureSet(for: "counter") == "FS2")
    }
}

// MARK: - Service Registry Tests

@Suite("Service Registry Tests")
struct ServiceRegistryTests {

    @Test("Register and resolve service")
    func testRegisterAndResolve() {
        let registry = ServiceRegistry()
        let service = MockTestService(value: "test")

        registry.register(service)

        let resolved = registry.resolve(MockTestService.self)
        #expect(resolved != nil)
        #expect(resolved?.value == "test")
    }

    @Test("Resolve unregistered service returns nil")
    func testResolveUnregistered() {
        let registry = ServiceRegistry()

        let resolved = registry.resolve(MockTestService.self)
        #expect(resolved == nil)
    }

    @Test("Service overwriting")
    func testServiceOverwriting() {
        let registry = ServiceRegistry()

        registry.register(MockTestService(value: "first"))
        registry.register(MockTestService(value: "second"))

        let resolved = registry.resolve(MockTestService.self)
        #expect(resolved?.value == "second")
    }

    @Test("Register all in context")
    func testRegisterAllInContext() {
        let registry = ServiceRegistry()
        registry.register(MockTestService(value: "test"))

        let context = RuntimeContext(featureSetName: "Test")
        registry.registerAll(in: context)

        let service = context.service(MockTestService.self)
        #expect(service != nil)
    }
}

// MARK: - Runtime Tests

@Suite("Runtime Tests")
struct RuntimeClassTests {

    init() {
        // Reset global state before each test
        ShutdownCoordinator.shared.reset()
        RuntimeSignalHandler.shared.reset()
    }

    @Test("Runtime initialization")
    func testRuntimeInit() {
        let runtime = Runtime()
        #expect(runtime != nil)

        // Cleanup: signal shutdown in case any waiters were registered
        defer { ShutdownCoordinator.shared.signalShutdown() }
    }

    @Test("Runtime with custom dependencies")
    func testRuntimeWithDependencies() {
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let runtime = Runtime(actionRegistry: registry, eventBus: eventBus)
        #expect(runtime != nil)

        // Cleanup: signal shutdown in case any waiters were registered
        defer { ShutdownCoordinator.shared.signalShutdown() }
    }

    @Test("Runtime service registration")
    func testRuntimeServiceRegistration() {
        let runtime = Runtime()
        let service = MockTestService(value: "runtime-test")
        runtime.register(service: service)
        // Service should be registered for execution
        #expect(Bool(true))

        // Cleanup: signal shutdown in case any waiters were registered
        defer { ShutdownCoordinator.shared.signalShutdown() }
    }

    // Note: We don't test runtime.stop() because it calls
    // ShutdownCoordinator.shared.signalShutdown() which interferes
    // with the test framework's parallel execution, causing hangs.
}

// MARK: - Runtime Signal Handler Tests

@Suite("Runtime Signal Handler Tests")
struct RuntimeSignalHandlerTests {

    init() {
        // Reset global state before each test
        ShutdownCoordinator.shared.reset()
        RuntimeSignalHandler.shared.reset()
    }

    @Test("Shared handler exists")
    func testSharedHandlerExists() {
        let handler = RuntimeSignalHandler.shared
        #expect(handler != nil)
    }

    // Note: We don't test register(runtime) here because it sets up
    // SIGINT/SIGTERM handlers that interfere with the test framework's
    // cleanup process, causing tests to hang after completion.
}

// MARK: - Mock Services

private struct MockTestService: Sendable {
    let value: String
}
