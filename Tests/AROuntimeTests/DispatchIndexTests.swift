// ============================================================
// DispatchIndexTests.swift
// ARO Runtime - Activity→FeatureSet Dispatch Index Tests (Issue #158)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Dispatch Index Tests")
struct DispatchIndexTests {

    // MARK: - Helpers

    /// Build an AnalyzedProgram from ARO source so all constructors are handled internally.
    private func compile(_ source: String) throws -> AnalyzedProgram {
        return try SemanticAnalyzer.analyze(source)
    }

    // MARK: - byActivity Index

    @Test("byActivity groups feature sets by business activity")
    func testByActivityGrouping() throws {
        let prog = try compile("""
        (handleCreate1: UserCreated Handler) { Log "a" to the <console>. }
        (handleCreate2: UserCreated Handler) { Log "b" to the <console>. }
        (handleUpdate:  UserUpdated Handler) { Log "c" to the <console>. }
        (listUsers:     listUsers)           { Log "d" to the <console>. }
        """)

        #expect(prog.byActivity["UserCreated Handler"]?.count == 2)
        #expect(prog.byActivity["UserUpdated Handler"]?.count == 1)
        #expect(prog.byActivity["listUsers"]?.count == 1)
    }

    @Test("byActivity covers all feature sets")
    func testByActivityCompleteness() throws {
        let prog = try compile("""
        (Application-Start: My App)        { Log "start" to the <console>. }
        (listUsers:         listUsers)     { Log "list" to the <console>. }
        (onUserCreated:     UserCreated Handler) { Log "ev" to the <console>. }
        (watchUsers:        user-repository Observer) { Log "obs" to the <console>. }
        """)

        let totalViaIndex = prog.byActivity.values.reduce(0) { $0 + $1.count }
        #expect(totalViaIndex == prog.featureSets.count)
    }

    // MARK: - byName Index

    @Test("byName indexes feature sets by name for O(1) lookup")
    func testByNameLookup() throws {
        let prog = try compile("""
        (Application-Start: My App) { Log "a" to the <console>. }
        (listUsers:         listUsers) { Log "b" to the <console>. }
        (createUser:        createUser) { Log "c" to the <console>. }
        """)

        #expect(prog.byName["Application-Start"]?.featureSet.name == "Application-Start")
        #expect(prog.byName["listUsers"]?.featureSet.name == "listUsers")
        #expect(prog.byName["createUser"]?.featureSet.name == "createUser")
        #expect(prog.byName["nonexistent"] == nil)
    }

    @Test("byName returns correct business activity")
    func testByNameActivity() throws {
        let prog = try compile("""
        (onUserCreated: UserCreated Handler) { Log "ev" to the <console>. }
        """)
        #expect(prog.byName["onUserCreated"]?.featureSet.businessActivity == "UserCreated Handler")
    }

    @Test("byName count equals featureSets count when names are unique")
    func testByNameCount() throws {
        let prog = try compile("""
        (fs1: Activity1) { Log "a" to the <console>. }
        (fs2: Activity2) { Log "b" to the <console>. }
        (fs3: Activity3) { Log "c" to the <console>. }
        """)
        #expect(prog.byName.count == prog.featureSets.count)
    }

    // MARK: - Dispatch Pattern Filters

    @Test("byActivity filter finds domain Handler feature sets")
    func testHandlerPatternFilter() throws {
        let prog = try compile("""
        (onUserCreated: UserCreated Handler)     { Log "a" to the <console>. }
        (onOrderPlaced: OrderPlaced Handler)     { Log "b" to the <console>. }
        (socketConn:    Socket Event Handler)    { Log "c" to the <console>. }
        (listUsers:     listUsers)               { Log "d" to the <console>. }
        """)

        let domainHandlers = prog.byActivity
            .filter { key, _ in
                key.contains(" Handler") &&
                !key.contains("Socket Event Handler") &&
                !key.contains("WebSocket Event Handler") &&
                !key.contains("File Event Handler") &&
                !key.contains("Application-End")
            }
            .flatMap { $0.value }

        #expect(domainHandlers.count == 2)
        #expect(Set(domainHandlers.map { $0.featureSet.name }) == ["onUserCreated", "onOrderPlaced"])
    }

    @Test("byActivity filter finds Observer feature sets")
    func testObserverPatternFilter() throws {
        let prog = try compile("""
        (watchUsers:  user-repository Observer)  { Log "a" to the <console>. }
        (watchOrders: order-repository Observer) { Log "b" to the <console>. }
        (listUsers:   listUsers)                 { Log "c" to the <console>. }
        """)

        let observers = prog.byActivity
            .filter { $0.key.contains(" Observer") && $0.key.contains("-repository") }
            .flatMap { $0.value }

        #expect(observers.count == 2)
    }

    @Test("byActivity filter finds File Event Handlers")
    func testFileEventHandlerFilter() throws {
        let prog = try compile("""
        (onCreate: File Event Handler) { Log "a" to the <console>. }
        (onModify: File Event Handler) { Log "b" to the <console>. }
        (listUsers: listUsers)         { Log "c" to the <console>. }
        """)

        let fileHandlers = prog.byActivity
            .filter { $0.key.contains("File Event Handler") }
            .flatMap { $0.value }

        // Both share the same activity key, so they're grouped together
        #expect(fileHandlers.count == 2)
    }

    @Test("empty program produces empty indices")
    func testEmptyProgram() throws {
        let prog = try compile("")
        #expect(prog.byActivity.isEmpty)
        #expect(prog.byName.isEmpty)
    }
}
