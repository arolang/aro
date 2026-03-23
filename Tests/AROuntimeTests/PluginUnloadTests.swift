// ============================================================
// PluginUnloadTests.swift
// ARO Runtime - Plugin unload / ActionRegistry cleanup tests
// ============================================================

import XCTest
@testable import ARORuntime

/// Tests for issue #153: plugin unload must deregister verbs from ActionRegistry
/// and qualifiers from QualifierRegistry, and UnifiedPluginLoader must expose
/// single-plugin unload and reload APIs.
///
/// All tests use uniquely-prefixed verb names so they do not collide with
/// built-in actions or verbs registered by parallel test cases.
final class PluginUnloadTests: XCTestCase {

    // Unique prefix per test run to avoid cross-test pollution on the shared registry
    private var prefix: String = ""

    override func setUp() {
        super.setUp()
        prefix = "test-\(UUID().uuidString.prefix(8).lowercased())"
    }

    // MARK: - ActionRegistry.registerDynamic / unregisterPlugin

    func testRegisterDynamicWithPluginNameTracksVerb() async {
        let verb = "\(prefix)-greet"
        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }

        await ActionRegistry.shared.registerDynamic(verb: verb, handler: dummy, pluginName: "\(prefix)-plugin")

        let handler = await ActionRegistry.shared.dynamicHandler(for: verb)
        XCTAssertNotNil(handler, "Verb should be registered")

        await ActionRegistry.shared.unregisterPlugin("\(prefix)-plugin")
    }

    func testUnregisterPluginRemovesAllItsVerbs() async {
        let pluginName = "\(prefix)-greeting-plugin"
        let otherPlugin = "\(prefix)-other-plugin"
        let verbA = "\(prefix)-greet"
        let verbB = "\(prefix)-farewell"
        let verbC = "\(prefix)-unrelated"

        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }
        await ActionRegistry.shared.registerDynamic(verb: verbA, handler: dummy, pluginName: pluginName)
        await ActionRegistry.shared.registerDynamic(verb: verbB, handler: dummy, pluginName: pluginName)
        await ActionRegistry.shared.registerDynamic(verb: verbC, handler: dummy, pluginName: otherPlugin)

        await ActionRegistry.shared.unregisterPlugin(pluginName)

        let greetHandler    = await ActionRegistry.shared.dynamicHandler(for: verbA)
        let farewellHandler = await ActionRegistry.shared.dynamicHandler(for: verbB)
        let unrelatedHandler = await ActionRegistry.shared.dynamicHandler(for: verbC)

        XCTAssertNil(greetHandler,    "greet should be removed after plugin unload")
        XCTAssertNil(farewellHandler, "farewell should be removed after plugin unload")
        XCTAssertNotNil(unrelatedHandler, "other-plugin verbs must not be affected")

        await ActionRegistry.shared.unregisterPlugin(otherPlugin)
    }

    func testUnregisterPluginWithNoRegisteredVerbsIsNoop() async {
        // Should not crash
        await ActionRegistry.shared.unregisterPlugin("\(prefix)-nonexistent")
    }

    func testUnregisterPluginTwiceIsNoop() async {
        let pluginName = "\(prefix)-hash-plugin"
        let verb = "\(prefix)-hash"
        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }

        await ActionRegistry.shared.registerDynamic(verb: verb, handler: dummy, pluginName: pluginName)
        await ActionRegistry.shared.unregisterPlugin(pluginName)
        await ActionRegistry.shared.unregisterPlugin(pluginName) // must not crash

        let handler = await ActionRegistry.shared.dynamicHandler(for: verb)
        XCTAssertNil(handler)
    }

    func testRegisterDynamicWithoutPluginNameIsNotTracked() async {
        // Verbs registered without a pluginName should still work but are not
        // affected by unregisterPlugin calls.
        let verb = "\(prefix)-legacy-verb"
        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }

        await ActionRegistry.shared.registerDynamic(verb: verb, handler: dummy)

        await ActionRegistry.shared.unregisterPlugin("\(prefix)-any-plugin")

        let handler = await ActionRegistry.shared.dynamicHandler(for: verb)
        XCTAssertNotNil(handler, "Untracked verb must survive unregisterPlugin")

        await ActionRegistry.shared.unregister(verb: verb)
    }

    func testNormalisedVerbsAreUnregistered() async {
        // registerDynamic normalises "parse-csv" → "parsecsv"; unregisterPlugin
        // must remove the normalised key.
        let pluginName = "\(prefix)-csv-plugin"
        let verb = "\(prefix)-parse-csv"
        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }

        await ActionRegistry.shared.registerDynamic(verb: verb, handler: dummy, pluginName: pluginName)

        let before = await ActionRegistry.shared.dynamicHandler(for: verb)
        XCTAssertNotNil(before)

        await ActionRegistry.shared.unregisterPlugin(pluginName)

        let after = await ActionRegistry.shared.dynamicHandler(for: verb)
        XCTAssertNil(after, "Normalised verb key must be removed")
    }

    func testMultiplePluginsIndependentlyUnregister() async {
        let pluginA = "\(prefix)-plugin-a"
        let pluginB = "\(prefix)-plugin-b"
        let verbA = "\(prefix)-action-a"
        let verbB = "\(prefix)-action-b"
        let dummy: ActionRegistry.DynamicActionHandler = { _, _, _ in "ok" }

        await ActionRegistry.shared.registerDynamic(verb: verbA, handler: dummy, pluginName: pluginA)
        await ActionRegistry.shared.registerDynamic(verb: verbB, handler: dummy, pluginName: pluginB)

        await ActionRegistry.shared.unregisterPlugin(pluginA)

        let handlerA = await ActionRegistry.shared.dynamicHandler(for: verbA)
        let handlerB = await ActionRegistry.shared.dynamicHandler(for: verbB)

        XCTAssertNil(handlerA,    "plugin-a verb should be gone")
        XCTAssertNotNil(handlerB, "plugin-b verb must remain")

        await ActionRegistry.shared.unregisterPlugin(pluginB)
    }

    // MARK: - UnifiedPluginLoader.unload(pluginName:)

    func testUnloadUnknownPluginReturnsFalse() {
        let result = UnifiedPluginLoader.shared.unload(pluginName: "\(prefix)-does-not-exist")
        XCTAssertFalse(result, "Unloading an unknown plugin should return false")
    }

    // MARK: - UnifiedPluginLoader.reload(pluginName:)

    func testReloadUnknownPluginThrows() {
        XCTAssertThrowsError(
            try UnifiedPluginLoader.shared.reload(pluginName: "\(prefix)-does-not-exist")
        ) { error in
            guard case UnifiedPluginError.notFound(let name) = error else {
                return XCTFail("Expected UnifiedPluginError.notFound, got \(error)")
            }
            XCTAssertEqual(name, "\(prefix)-does-not-exist")
        }
    }

    // MARK: - UnifiedPluginError description

    func testUnifiedPluginErrorDescription() {
        let err = UnifiedPluginError.notFound("my-plugin")
        XCTAssertTrue(err.description.contains("my-plugin"))
    }
}
