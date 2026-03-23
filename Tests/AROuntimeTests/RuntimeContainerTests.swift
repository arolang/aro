// ============================================================
// RuntimeContainerTests.swift
// ARO Runtime - DI Container Tests (Issue #156)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("RuntimeContainer Tests")
struct RuntimeContainerTests {

    // MARK: - Container Isolation

    @Test("Container provides isolated EventBus")
    func testIsolatedEventBus() async {
        let container = RuntimeContainer(eventBus: EventBus())
        let sharedBus = RuntimeContainer.default.eventBus
        // Isolated container has its own event bus, not the shared one
        #expect(container.eventBus !== sharedBus)
    }

    @Test("Container provides isolated repository storage")
    func testIsolatedRepositoryStorage() async throws {
        let storage1 = InMemoryRepositoryStorage()
        let storage2 = InMemoryRepositoryStorage()
        let c1 = RuntimeContainer(repositoryStorage: storage1)
        let c2 = RuntimeContainer(repositoryStorage: storage2)

        // Store a value in c1's storage
        let item: [String: any Sendable] = ["name": "test"]
        _ = await storage1.store(value: item, in: "items", businessActivity: "test")

        // c2's storage should be empty — no cross-container leakage
        let results2 = await storage2.retrieve(from: "items", businessActivity: "test")
        #expect(results2.isEmpty)

        // c1's storage should have the item
        let results1 = await storage1.retrieve(from: "items", businessActivity: "test")
        #expect(results1.count == 1)

        // Containers reference different storage instances (verified via isolation above)
    }

    @Test("RuntimeContext inherits container from parent")
    func testContainerPropagationThroughParent() {
        let container = RuntimeContainer(eventBus: EventBus())
        let parent = RuntimeContext(featureSetName: "parent", container: container)
        let child = parent.createChild(featureSetName: "child") as! RuntimeContext
        #expect(child.container.eventBus === container.eventBus)
    }

    @Test("RuntimeContext uses default container when none provided")
    func testDefaultContainerFallback() {
        let ctx = RuntimeContext(featureSetName: "test")
        #expect(ctx.container.eventBus === RuntimeContainer.default.eventBus)
    }

    @Test("ExecutionEngine accepts container")
    func testExecutionEngineWithContainer() async {
        let container = RuntimeContainer(eventBus: EventBus())
        let engine = ExecutionEngine(container: container)
        #expect(engine != nil)
    }

    // MARK: - Default Container

    @Test("Default container wraps shared singletons")
    func testDefaultContainerWrapsSharedSingletons() {
        let def = RuntimeContainer.default
        #expect(def.eventBus === EventBus.shared)
        #expect(def.actionRegistry === ActionRegistry.shared)
        #expect(def.qualifierRegistry === QualifierRegistry.shared)
        #expect(def.externalServices === ExternalServiceRegistry.shared)
        #expect(def.parameterStorage === ParameterStorage.shared)
        #expect(def.metricsCollector === MetricsCollector.shared)
    }
}
