// ============================================================
// LazyPluginLoadingTests.swift
// ARO Runtime - Lazy Plugin Loading Tests (Issue #157)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Lazy Plugin Loading Tests")
struct LazyPluginLoadingTests {

    // MARK: - Manifest Parsing

    @Test("ManifestActionEntry decodes from YAML-compatible JSON")
    func testManifestActionEntryDecodes() throws {
        let json = """
        {
            "name": "Hash",
            "verbs": ["hash", "digest"],
            "role": "own",
            "description": "Compute hash"
        }
        """
        let data = json.data(using: .utf8)!
        let entry = try JSONDecoder().decode(ManifestActionEntry.self, from: data)
        #expect(entry.name == "Hash")
        #expect(entry.verbs == ["hash", "digest"])
        #expect(entry.role == "own")
        #expect(entry.description == "Compute hash")
    }

    @Test("UnifiedProvideEntry decodes actions array")
    func testProvideEntryDecodesActions() throws {
        let json = """
        {
            "type": "c-plugin",
            "path": "src/",
            "actions": [
                {"name": "Hash", "verbs": ["hash", "digest"]},
                {"name": "DJB2", "verbs": ["djb2"]}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let entry = try JSONDecoder().decode(UnifiedProvideEntry.self, from: data)
        #expect(entry.type == "c-plugin")
        #expect(entry.actions?.count == 2)
        #expect(entry.actions?[0].name == "Hash")
        #expect(entry.actions?[0].verbs == ["hash", "digest"])
        #expect(entry.actions?[1].name == "DJB2")
    }

    @Test("UnifiedProvideEntry without actions field has nil actions")
    func testProvideEntryNilActionsWhenAbsent() throws {
        let json = """
        {
            "type": "c-plugin",
            "path": "src/"
        }
        """
        let data = json.data(using: .utf8)!
        let entry = try JSONDecoder().decode(UnifiedProvideEntry.self, from: data)
        #expect(entry.actions == nil)
    }

    // MARK: - Plugin State

    @Test("Plugin is not loaded before first use")
    func testPluginNotLoadedBeforeFirstUse() {
        let loader = UnifiedPluginLoader.shared
        // A plugin that doesn't exist at all should not be reported as loaded
        #expect(!loader.isPluginLoaded(name: "nonexistent-plugin-xyz"))
    }

    // MARK: - buildPluginInput helper

    @Test("buildPluginInput includes object base value")
    func testBuildPluginInputIncludesObjectValue() {
        let ctx = RuntimeContext(featureSetName: "test")
        ctx.bind("mydata", value: "hello")

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "output", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "mydata", specifiers: [], span: span)

        let input = UnifiedPluginLoader.buildPluginInput(result: result, object: object, context: ctx)

        #expect(input["data"] as? String == "hello")
        #expect(input["object"] as? String == "hello")
        #expect(input["mydata"] as? String == "hello")
    }

    @Test("buildPluginInput merges expression args")
    func testBuildPluginInputMergesExpressionArgs() {
        let ctx = RuntimeContext(featureSetName: "test")
        let exprArgs: [String: any Sendable] = ["url": "https://example.com", "method": "GET"]
        ctx.bind("_expression_", value: exprArgs)

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "output", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "http", specifiers: [], span: span)

        let input = UnifiedPluginLoader.buildPluginInput(result: result, object: object, context: ctx)

        #expect(input["url"] as? String == "https://example.com")
        #expect(input["method"] as? String == "GET")
    }

    @Test("buildPluginInput includes first specifier as qualifier")
    func testBuildPluginInputIncludesSpecifierAsQualifier() {
        let ctx = RuntimeContext(featureSetName: "test")
        ctx.bind("items", value: ["a", "b", "c"])

        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "output", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "items", specifiers: ["reverse"], span: span)

        let input = UnifiedPluginLoader.buildPluginInput(result: result, object: object, context: ctx)

        #expect(input["qualifier"] as? String == "reverse")
    }
}
