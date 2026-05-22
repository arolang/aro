// ============================================================
// AROCatalogTests.swift
// Tests for the AROCatalog discovery service (Issue #225)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

@Suite("AROCatalog Tests")
struct AROCatalogTests {

    // MARK: - Built-in coverage

    @Test("actions() exposes all built-in roles")
    func actionsExposesAllRoles() async {
        let entries = AROCatalog.shared.actions()

        // Built-ins should populate every role at least once.
        let roles = Set(entries.compactMap { entry -> ActionRole? in
            guard case .builtin = entry.origin else { return nil }
            return entry.role
        })
        #expect(roles.contains(.request))
        #expect(roles.contains(.own))
        #expect(roles.contains(.response))
        #expect(roles.contains(.export))
        #expect(roles.contains(.server))
    }

    @Test("actions(role:) filters by semantic role")
    func actionsRoleFilter() async {
        let response = AROCatalog.shared.actions(role: .response)
        // Only RESPONSE-class verbs should be present.
        #expect(response.allSatisfy { $0.role == .response })
        // "Return" is canonically RESPONSE.
        #expect(response.contains { $0.verb.lowercased() == "return" })
        // "Compute" is OWN, must not appear.
        #expect(!response.contains { $0.verb.lowercased() == "compute" })
    }

    @Test("Built-in actions carry descriptions")
    func builtInActionsHaveDescriptions() async {
        let entries = AROCatalog.shared.actions()
        let extract = entries.first { $0.verb.lowercased() == "extract" }
        #expect(extract?.description != nil)
    }

    // MARK: - Qualifiers

    @Test("qualifiers() returns built-in qualifiers")
    func qualifiersReturnsBuiltIns() async {
        let entries = AROCatalog.shared.qualifiers()
        // BuiltInQualifierHost registers these; the catalog flattens namespace == "".
        let names = entries.map { $0.qualifier }
        #expect(names.contains("uppercase"))
        #expect(names.contains("lowercase"))
        #expect(names.contains("hash"))
    }

    @Test("Built-in qualifiers have empty namespace")
    func builtInQualifiersAreUnnamespaced() async {
        let entries = AROCatalog.shared.qualifiers()
        let upper = entries.first { $0.qualifier == "uppercase" }
        #expect(upper?.namespace == "")
        #expect(upper?.fullName == "uppercase")
    }

    // MARK: - Plugin metadata flow

    @Test("registerDynamic with metadata appears in catalog")
    func dynamicMetadataFlowsToCatalog() async {
        // Register a plugin verb directly into ActionRegistry, then verify the
        // catalog surfaces the metadata. The verb name is unique so this test
        // doesn't conflict with built-ins.
        let verb = "issue225_test_verb_xyz"
        let metadata = ActionRegistry.PluginActionMetadata(
            role: .own,
            prepositions: ["from", "with"],
            description: "A synthetic verb for the catalog test",
            handle: "TestHandle",
            since: "1.0.0"
        )

        ActionRegistry.shared.registerDynamic(
            verb: verb,
            handler: { _, _, _ in NSNull() },
            pluginName: "_catalog_test_plugin_",
            metadata: metadata
        )
        defer {
            // Clean up so other tests don't see this verb.
            ActionRegistry.shared.unregisterPlugin("_catalog_test_plugin_")
        }

        let entries = AROCatalog.shared.actions()
        let entry = entries.first { $0.verb.lowercased() == verb.lowercased() }
        #expect(entry != nil)
        #expect(entry?.role == .own)
        #expect(entry?.description == "A synthetic verb for the catalog test")
        #expect(entry?.prepositions == ["from", "with"])
        if case .plugin(let name, let handle) = entry?.origin {
            #expect(name == "_catalog_test_plugin_")
            #expect(handle == "TestHandle")
        } else {
            Issue.record("Expected entry to have plugin origin, got \(String(describing: entry?.origin))")
        }
    }

    @Test("ActionRegistry.isRegistered sees dynamic plugin verbs")
    func isRegisteredFindsDynamicVerbs() {
        let verb = "issue225_isregistered_xyz"
        ActionRegistry.shared.registerDynamic(
            verb: verb,
            handler: { _, _, _ in NSNull() },
            pluginName: "_isregistered_test_"
        )
        defer { ActionRegistry.shared.unregisterPlugin("_isregistered_test_") }

        let registered = ActionRegistry.shared.isRegistered(verb)
        #expect(registered == true)
    }

    // MARK: - Synchronous snapshots

    @Test("actionsSnapshot returns built-in actions consistent with async API")
    func actionsSnapshotReturnsBuiltIns() async {
        let sync = AROCatalog.actionsSnapshot()
        // Built-in count is stable across the snapshot and async paths even
        // when other tests inject transient plugin verbs in parallel.
        let syncBuiltInCount = sync.filter {
            if case .builtin = $0.origin { return true }
            return false
        }.count
        let asyncBuiltInCount = (AROCatalog.shared.actions()).filter {
            if case .builtin = $0.origin { return true }
            return false
        }.count
        #expect(syncBuiltInCount == asyncBuiltInCount)
        #expect(syncBuiltInCount > 30) // We have many built-ins.
    }

    @Test("qualifiersSnapshot returns built-in qualifiers")
    func qualifiersSnapshotReturnsBuiltIns() {
        let entries = AROCatalog.qualifiersSnapshot()
        #expect(entries.contains { $0.qualifier == "uppercase" })
    }

    // MARK: - Workspace loading

    @Test("loadPluginsFromWorkspace handles missing Plugins dir")
    func loadPluginsFromMissingDirReturnsFalse() async {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-catalog-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let loaded = await AROCatalog.shared.loadPluginsFromWorkspace(tmp)
        #expect(loaded == false)
        let hasLoaded = await AROCatalog.shared.hasLoaded(tmp)
        #expect(hasLoaded == false)
    }
}
