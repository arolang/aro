// ============================================================
// FeatureSetExecutorTests.swift
// ARO Runtime - Feature Set Executor Unit Tests
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

// MARK: - Feature Set Executor Tests

@Suite("Feature Set Executor Tests")
struct FeatureSetExecutorTests {

    func createExecutor(enableParallelIO: Bool = false) -> FeatureSetExecutor {
        FeatureSetExecutor(
            actionRegistry: ActionRegistry.shared,
            eventBus: EventBus(),
            globalSymbols: GlobalSymbolStorage(),
            enableParallelIO: enableParallelIO
        )
    }

    @Test("Executor initialization")
    func testExecutorInit() {
        let executor = createExecutor()
        #expect(executor.enableParallelIO == false)
    }

    @Test("Executor with parallel IO enabled")
    func testExecutorParallelIO() {
        let executor = createExecutor(enableParallelIO: true)
        #expect(executor.enableParallelIO == true)
    }

    @Test("Enable parallel IO property")
    func testEnableParallelIOProperty() {
        var executor = createExecutor()
        #expect(executor.enableParallelIO == false)

        executor.enableParallelIO = true
        #expect(executor.enableParallelIO == true)
    }

    @Test("Executor can be created with custom dependencies")
    func testExecutorCustomDependencies() {
        let registry = ActionRegistry.shared
        let eventBus = EventBus()
        let globalSymbols = GlobalSymbolStorage()

        let executor = FeatureSetExecutor(
            actionRegistry: registry,
            eventBus: eventBus,
            globalSymbols: globalSymbols
        )

        #expect(executor.enableParallelIO == false)
    }
}

// MARK: - Global Symbol Storage Integration Tests

@Suite("Global Symbol Storage Integration Tests")
struct GlobalSymbolStorageIntegrationTests {

    @Test("Symbols are isolated by business activity")
    func testSymbolIsolation() {
        let storage = GlobalSymbolStorage()

        // Publish in Activity1
        storage.publish(name: "config", value: "value1", fromFeatureSet: "FS1", businessActivity: "Activity1")

        // Should resolve in same activity
        let value1: String? = storage.resolve("config", forBusinessActivity: "Activity1")
        #expect(value1 == "value1")

        // Should NOT resolve in different activity
        let value2: String? = storage.resolve("config", forBusinessActivity: "Activity2")
        #expect(value2 == nil)
    }

    @Test("Empty business activity is accessible from anywhere")
    func testEmptyBusinessActivity() {
        let storage = GlobalSymbolStorage()

        // Publish with empty business activity (framework-level)
        storage.publish(name: "global", value: "accessible", fromFeatureSet: "Framework", businessActivity: "")

        // Should be accessible from any activity
        let value1: String? = storage.resolve("global", forBusinessActivity: "Activity1")
        let value2: String? = storage.resolve("global", forBusinessActivity: "Activity2")

        #expect(value1 == "accessible")
        #expect(value2 == "accessible")
    }
}

// MARK: - Publish Statement Tests

@Suite("Publish Statement Execution Tests")
struct PublishStatementExecutorTests {

    @Test("Published variables are stored in global symbols")
    func testPublishToGlobalSymbols() {
        let storage = GlobalSymbolStorage()

        storage.publish(name: "exported", value: "test value", fromFeatureSet: "TestFS", businessActivity: "TestActivity")

        let value: String? = storage.resolve("exported", forBusinessActivity: "TestActivity")
        #expect(value == "test value")

        #expect(storage.sourceFeatureSet(for: "exported") == "TestFS")
        #expect(storage.businessActivity(for: "exported") == "TestActivity")
    }
}

// MARK: - Shutdown Coordinator Tests

@Suite("Shutdown Coordinator Tests")
struct ShutdownCoordinatorTests {

    @Test("Shared coordinator exists")
    func testSharedCoordinator() {
        let coordinator = ShutdownCoordinator.shared
        #expect(coordinator != nil)
    }

    @Test("Coordinator can be reset")
    func testCoordinatorReset() {
        let coordinator = ShutdownCoordinator.shared
        coordinator.reset()
        #expect(true)
    }

    @Test("Coordinator can signal shutdown")
    func testCoordinatorSignal() {
        let coordinator = ShutdownCoordinator.shared
        coordinator.signalShutdown()
        #expect(true)
    }
}
