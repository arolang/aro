// ============================================================
// CallerScopedStorageTests.swift
// ARO Runtime — the partition actually separates callers
// ARO-0094, GitLab #885
// ============================================================
//
// `RepositoryScopeTests` covers the decision — which partition a caller may
// touch. These cover the consequence: that two callers writing the same
// repository do not see each other's rows, and that an application-scoped
// repository keys exactly as it did before ARO-0094, since every existing
// program depends on that and nothing would tell us if it stopped being true.

import Testing
import Foundation
@testable import ARORuntime

@Suite("Caller-scoped storage (ARO-0094)", .serialized)
struct CallerScopedStorageTests {

    private func storage() -> InMemoryRepositoryStorage { InMemoryRepositoryStorage() }

    @Test("Two sessions writing one repository never see each other")
    func sessionsAreIsolated() async {
        let store = storage()
        await store.store(value: ["id": "1", "item": "alice-hat"] as [String: any Sendable],
                          in: "cart-repository", businessActivity: "Shop", caller: "session:alice")
        await store.store(value: ["id": "1", "item": "bob-boot"] as [String: any Sendable],
                          in: "cart-repository", businessActivity: "Shop", caller: "session:bob")

        let alice = await store.retrieve(from: "cart-repository", businessActivity: "Shop",
                                         caller: "session:alice")
        let bob = await store.retrieve(from: "cart-repository", businessActivity: "Shop",
                                       caller: "session:bob")
        #expect(alice.count == 1)
        #expect(bob.count == 1)
        // Same row id in both partitions — which is the point. The id is only
        // unique within a caller, exactly as it would be in a per-user database.
        #expect((alice.first as? [String: any Sendable])?["item"] as? String == "alice-hat")
        #expect((bob.first as? [String: any Sendable])?["item"] as? String == "bob-boot")
    }

    @Test("The application partition is the key it has always been")
    func applicationPartitionUnchanged() async {
        // The migration promise (§11): a program that never writes `Declare`
        // behaves exactly as it does today. A caller-less write and a write
        // with the empty partition must land in the same place.
        let store = storage()
        await store.store(value: ["id": "1", "name": "hat"] as [String: any Sendable],
                          in: "catalogue-repository", businessActivity: "Shop")
        let viaPartition = await store.retrieve(from: "catalogue-repository",
                                                businessActivity: "Shop", caller: "")
        #expect(viaPartition.count == 1)

        let viaOldArity = await store.retrieve(from: "catalogue-repository", businessActivity: "Shop")
        #expect(viaOldArity.count == 1)
    }

    @Test("A caller cannot read another's rows through a where clause")
    func filteredReadsStayInThePartition() async {
        let store = storage()
        await store.store(value: ["id": "1", "owner": "alice"] as [String: any Sendable],
                          in: "cart-repository", businessActivity: "Shop", caller: "session:alice")
        let bobLooking = await store.retrieve(from: "cart-repository", businessActivity: "Shop",
                                              caller: "session:bob", where: "owner", equals: "alice")
        #expect(bobLooking.isEmpty, "the filter runs inside bob's partition, which is empty")
    }

    @Test("Dropping a partition leaves the others alone")
    func dropPartitionIsTargeted() async {
        let store = storage()
        for caller in ["conn:a", "conn:b", ""] {
            await store.store(value: ["id": "1"] as [String: any Sendable],
                              in: "partial-repository", businessActivity: "Shop", caller: caller)
        }
        let dropped = await store.dropPartition(caller: "conn:a")
        #expect(dropped == ["partial-repository"])

        #expect(await store.retrieve(from: "partial-repository", businessActivity: "Shop",
                                     caller: "conn:a").isEmpty)
        #expect(await store.retrieve(from: "partial-repository", businessActivity: "Shop",
                                     caller: "conn:b").count == 1)
        #expect(await store.retrieve(from: "partial-repository", businessActivity: "Shop",
                                     caller: "").count == 1)
    }

    @Test("The application partition is never dropped")
    func applicationPartitionIsNotDroppable() async {
        // `dropPartition("")` would empty every application repository in the
        // process, and the caller that asks for it is a disconnect handler.
        let store = storage()
        await store.store(value: ["id": "1"] as [String: any Sendable],
                          in: "catalogue-repository", businessActivity: "Shop", caller: "")
        let dropped = await store.dropPartition(caller: "")
        #expect(dropped.isEmpty)
        #expect(await store.retrieve(from: "catalogue-repository", businessActivity: "Shop",
                                     caller: "").count == 1)
    }

    @Test("A deletion in one partition does not reach another")
    func deletesStayInThePartition() async {
        let store = storage()
        for caller in ["session:alice", "session:bob"] {
            await store.store(value: ["id": "1", "item": "hat"] as [String: any Sendable],
                              in: "cart-repository", businessActivity: "Shop", caller: caller)
        }
        let removed = await store.delete(from: "cart-repository", businessActivity: "Shop",
                                         caller: "session:alice", where: "item", equals: "hat")
        #expect(removed.count == 1)
        #expect(await store.retrieve(from: "cart-repository", businessActivity: "Shop",
                                     caller: "session:bob").count == 1)
    }

    // MARK: - The context

    @Test("A child context keeps its parent's caller")
    func callerIsInherited() {
        // Loop bodies, template renders and `Application.<Name>` frames are
        // all children. If any of them lost the caller, a nested `Store` would
        // write to a partition the enclosing `Retrieve` never looks in.
        let parent = RuntimeContext(featureSetName: "addToCart",
                                    businessActivity: "Shop API",
                                    caller: .session(id: "alice", connection: nil))
        let child = parent.createChild(featureSetName: "inner")
        #expect(child.caller == .session(id: "alice", connection: nil))

        let grandchild = child.createChild(featureSetName: "innermost")
        #expect(grandchild.caller == .session(id: "alice", connection: nil))
    }

    @Test("A context nobody attributed has no caller")
    func defaultCallerIsNone() {
        #expect(RuntimeContext(featureSetName: "Application-Start").caller == .none)
    }

    @Test("The partition helper refuses rather than falling back")
    func partitionHelperThrows() throws {
        let registry = RepositoryScopeRegistry.shared
        registry.reset()
        defer { registry.reset() }
        registry.declare("cart-repository", scope: .session)

        let anonymous = RuntimeContext(featureSetName: "Application-Start")
        #expect(throws: (any Error).self) {
            _ = try anonymous.repositoryPartition(of: "cart-repository")
        }

        // And an application repository still answers, for any caller at all.
        #expect(try anonymous.repositoryPartition(of: "catalogue-repository") == "")

        let alice = RuntimeContext(featureSetName: "addToCart",
                                   caller: .session(id: "alice", connection: nil))
        #expect(try alice.repositoryPartition(of: "cart-repository") == "session:alice")
    }
}
