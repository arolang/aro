// ============================================================
// PluginManifestHandleTests.swift
// ARORuntime — the handle scanner used by compiled binaries
// ============================================================
//
// A compiled binary has no plugin directory to read and no YAML
// parser in the loop: the manifest arrives as a string constant
// baked in at build time, and `parseHandlerFromPluginYAML` scans it
// by line. The interpreter takes a different route entirely — a
// real YAML parse — so any gap between the two shows up as an
// example that works under `aro run` and fails compiled.
//
// One did. `Examples/GreetingPlugin` declares:
//
//     handle: Greeting          # PascalCase namespace (ARO-0045); …
//
// and the scanner kept the comment, so every action registered
// under `greeting  # pascalcase ….greet` and the binary answered
// `Unknown action verb: 'greeting.greet'`. The manifest was valid
// YAML the whole time.

import Testing
@testable import ARORuntime

@Suite("Plugin manifest handle parsing")
struct PluginManifestHandleTests {

    // MARK: - The regression

    @Test("A trailing comment is not part of the handle")
    func trailingCommentStripped() {
        let yaml = """
        name: plugin-swift-hello
        version: 1.0.0
        handle: Greeting          # PascalCase namespace (ARO-0045); qualifiers: Greeting.x
        provides:
        - type: swift-plugin
          path: Sources/
        """
        #expect(PluginLoader.parseHandlerFromPluginYAML(yaml) == "Greeting")
    }

    @Test("The legacy handler: field strips comments too")
    func legacyHandlerCommentStripped() {
        let yaml = """
        name: plugin-collection
        provides:
        - type: swift-plugin
          handler: collections   # legacy fallback — use root-level handle:
        """
        #expect(PluginLoader.parseHandlerFromPluginYAML(yaml) == "collections")
    }

    // MARK: - What must keep working

    @Test("A bare handle is unchanged")
    func bareHandle() {
        #expect(PluginLoader.parseHandlerFromPluginYAML("handle: Greeting") == "Greeting")
    }

    @Test("Root-level handle wins over a legacy handler")
    func rootHandleWins() {
        let yaml = """
        handle: Greeting
        provides:
        - type: swift-plugin
          handler: greeting-legacy
        """
        #expect(PluginLoader.parseHandlerFromPluginYAML(yaml) == "Greeting")
    }

    @Test("An indented handle: is not the root-level field")
    func indentedHandleIgnored() {
        // Only a root-level `handle:` is the namespace; one nested under
        // `provides:` is something else's key.
        let yaml = """
        provides:
        - type: swift-plugin
          handle: NotTheNamespace
          handler: legacy
        """
        #expect(PluginLoader.parseHandlerFromPluginYAML(yaml) == "legacy")
    }

    @Test("A manifest with no handle at all yields nil")
    func noHandle() {
        #expect(PluginLoader.parseHandlerFromPluginYAML("name: x\nversion: 1.0.0") == nil)
    }

    @Test("Quoted handles keep their value", arguments: [
        "handle: \"Greeting\"",
        "handle: 'Greeting'",
    ])
    func quotedHandle(line: String) {
        #expect(PluginLoader.parseHandlerFromPluginYAML(line) == "Greeting")
    }

    // MARK: - Where the naive fix would have been wrong

    @Test("A # inside a quoted value is data, not a comment")
    func hashInsideQuotesKept() {
        #expect(PluginLoader.parseHandlerFromPluginYAML("handle: \"Grey#Matter\"") == "Grey#Matter")
    }

    @Test("A # not preceded by whitespace is data, not a comment")
    func hashWithoutSpaceKept() {
        // YAML only starts a comment at a `#` preceded by whitespace, so
        // stripping from the first `#` unconditionally would silently
        // truncate a legal handle.
        #expect(PluginLoader.parseHandlerFromPluginYAML("handle: Foo#1") == "Foo#1")
    }

    @Test("A comment after a quoted value is still stripped")
    func commentAfterQuotedValue() {
        #expect(PluginLoader.parseHandlerFromPluginYAML("handle: \"Greeting\"  # note") == "Greeting")
    }

    @Test("A handle that is only a comment yields nil")
    func commentOnlyValue() {
        // `handle:  # todo` declares nothing; treating the comment as the
        // namespace is how this bug worked.
        #expect(PluginLoader.parseHandlerFromPluginYAML("handle:  # todo\nname: x") == nil)
    }
}
