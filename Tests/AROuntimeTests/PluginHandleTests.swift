// ============================================================
// PluginHandleTests.swift
// ARORuntime — plugin namespaces and service wrappers
// (GitLab #825, #647)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

@Suite("Plugin service wrappers")
struct PluginServiceWrapperTests {

    /// Every plugin service wrapper is registered as an instance,
    /// because it needs the plugin host it wraps. They also conform to
    /// `AROService`, whose `init()` the registry can reach through the
    /// protocol — and that used to `fatalError`, taking the process
    /// down rather than failing one service lookup (#647).
    @Test func aWrapperBuiltWithoutItsPluginThrowsRatherThanTrapping() {
        #expect(throws: (any Error).self) {
            _ = try NativePluginServiceWrapper()
        }
        #expect(throws: (any Error).self) {
            _ = try PythonPluginServiceWrapper()
        }
    }

    @Test func theErrorSaysWhatIsMissing() throws {
        do {
            _ = try NativePluginServiceWrapper()
            Issue.record("expected a throw")
        } catch {
            // A message a person can act on, not just a non-crash.
            let text = String(describing: error)
            #expect(text.contains("register it as an instance"))
        }
    }
}

@Suite("Plugin handle resolution")
struct PluginHandleTests {

    /// Decoded from YAML rather than built by hand, so these exercise
    /// the same parse the loader performs on a real `plugin.yaml`.
    private func manifest(handle: String?, legacyHandler: String?)
    -> UnifiedPluginManifest {
        var yaml = """
        name: plugin-python-collection
        version: 1.0.0
        """
        if let handle { yaml += "\nhandle: \(handle)" }
        yaml += "\nprovides:\n- type: python-plugin\n  path: src/"
        if let legacyHandler { yaml += "\n  handler: \(legacyHandler)" }
        return try! UnifiedPluginLoader.shared.parseManifestForTesting(yaml: yaml)
    }

    @Test func theRootLevelHandleWins() {
        let loader = UnifiedPluginLoader.shared
        #expect(loader.effectiveHandleForTesting(
            manifest(handle: "Stats", legacyHandler: "collections")) == "Stats")
    }

    @Test func theLegacyKeyIsUsedWhenThereIsNoCanonicalOne() {
        let loader = UnifiedPluginLoader.shared
        #expect(loader.effectiveHandleForTesting(
            manifest(handle: nil, legacyHandler: "stats")) == "stats")
    }

    @Test func aPluginWithNoNamespaceResolvesToNothing() {
        let loader = UnifiedPluginLoader.shared
        #expect(loader.effectiveHandleForTesting(
            manifest(handle: nil, legacyHandler: nil)) == nil)
    }

    // MARK: - Mismatch detection

    @Test func agreementIsSilent() {
        // Case differs by convention — the manifest is PascalCase, the
        // namespace resolves lowercased — so that must not warn.
        #expect(!UnifiedPluginLoader.handlesDisagree(declared: "Stats",
                                                     effective: "stats"))
        #expect(!UnifiedPluginLoader.handlesDisagree(declared: "Stats",
                                                     effective: "Stats"))
    }

    @Test func aCodeDeclaredHandleThatDiffersIsAMismatch() {
        // The bug in `Examples/QualifierPluginPython`: the source said
        // Collections, the manifest said Stats, and every qualifier
        // answered to a namespace the source never mentions.
        #expect(UnifiedPluginLoader.handlesDisagree(declared: "Collections",
                                                    effective: "Stats"))
    }

    @Test func aPluginThatDeclaresNothingIsNotAMismatch() {
        // Most plugins declare no handle in code at all.
        #expect(!UnifiedPluginLoader.handlesDisagree(declared: nil,
                                                     effective: "Stats"))
        #expect(!UnifiedPluginLoader.handlesDisagree(declared: "",
                                                     effective: "Stats"))
    }
}
