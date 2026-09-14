// ============================================================
// PluginScaffoldTests.swift
// AROCLITests - `aro new plugin` scaffold generation
// ============================================================
//
// GitLab #511: `aro new plugin --qualifiers` used to scaffold plugins whose
// aro_plugin_info() DECLARED a qualifier but shipped no implementation and no
// aro_plugin_qualifier dispatch, so `<x: Handle.example>` failed at runtime
// out of the box. These tests scaffold into a temp directory and assert that
// every language template wires its example qualifier end-to-end using the
// language's SDK idiom (declaration + implementation + dispatch).

import Testing
import Foundation
@testable import AROCLI

@Suite("Plugin scaffold generation (GitLab #511)")
struct PluginScaffoldTests {

    // MARK: - Helpers

    private func options(
        language: PluginLanguage,
        actions: Bool = true,
        qualifiers: Bool = true
    ) -> ScaffoldOptions {
        ScaffoldOptions(
            pluginName:           "greeter",
            handle:               "Greeter",
            language:             language,
            includeActions:       actions,
            includeQualifiers:    qualifiers,
            includeServices:      false,
            includeSystemObjects: false,
            includeEvents:        false,
            includeTemplates:     false,
            includeHybrid:        false
        )
    }

    /// Run a scaffold's `generate()` in a fresh temp plugin dir and return the
    /// contents of one generated file.
    private func generateAndRead(
        language: PluginLanguage,
        file relativePath: String,
        actions: Bool = true,
        qualifiers: Bool = true
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-scaffold-tests-\(UUID().uuidString)")
        let pluginDir = root.appendingPathComponent("Plugins/greeter", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let scaffold = PluginScaffoldFactory.scaffold(for: language)
        _ = try scaffold.generate(
            options: options(language: language, actions: actions, qualifiers: qualifiers),
            pluginDir: pluginDir
        )

        let fileURL = pluginDir.appendingPathComponent(relativePath)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    // MARK: - Python

    @Test("Python scaffold wires the example qualifier through the SDK decorators")
    func pythonQualifierWiring() throws {
        let source = try generateAndRead(language: .python, file: "src/plugin.py")

        // SDK decorator form — declaration and implementation in one place.
        #expect(source.contains("from aro_plugin_sdk import"))
        #expect(source.contains("@qualifier(name=\"example\""))
        #expect(source.contains("def qualifier_example(input: AROInput)"))
        // export_abi generates the module-level aro_plugin_qualifier dispatch.
        #expect(source.contains("export_abi(globals())"))
        // The action is wired the same way.
        #expect(source.contains("@action("))
        #expect(source.contains("@plugin(name=\"greeter\", version=\"1.0.0\", handle=\"Greeter\")"))
        // The broken pattern must be gone: no hand-rolled info dict that
        // declares qualifiers nothing dispatches.
        #expect(!source.contains("def aro_plugin_info"))
    }

    @Test("Python scaffold with qualifiers only omits the action decorator")
    func pythonQualifiersOnly() throws {
        let source = try generateAndRead(
            language: .python, file: "src/plugin.py", actions: false)
        #expect(source.contains("@qualifier(name=\"example\""))
        #expect(!source.contains("@action("))
        #expect(source.contains("export_abi(globals())"))
    }

    // MARK: - Swift

    @Test("Swift scaffold wires the example qualifier through the AROPlugin builder")
    func swiftQualifierWiring() throws {
        let source = try generateAndRead(language: .swift, file: "Sources/GreeterPlugin.swift")

        // @AROExport generates aro_plugin_qualifier and friends.
        #expect(source.contains("import AROPluginKit"))
        #expect(source.contains("@AROExport"))
        #expect(source.contains(".qualifier(\"example\""))
        #expect(source.contains(".action(\"Example\""))
        // The broken pattern must be gone: no hand-rolled @_cdecl exports whose
        // execute switch was the only place the declared qualifier could reach.
        #expect(!source.contains("@_cdecl("))
        #expect(!source.contains("JSONSerialization"))

        // Package.swift must depend on the product that ships @AROExport.
        let package = try generateAndRead(language: .swift, file: "Package.swift")
        #expect(package.contains("AROPluginKit"))
    }

    // MARK: - Rust

    @Test("Rust scaffold wires the example qualifier through aro_export!")
    func rustQualifierWiring() throws {
        let source = try generateAndRead(language: .rust, file: "src/lib.rs")

        #expect(source.contains("use aro_plugin_sdk::prelude::*;"))
        // The prelude re-exports the qualifier attribute as `qualifier_attr`
        // (`qualifier` collides with the SDK's module of the same name).
        #expect(source.contains("#[qualifier_attr(name = \"example\""))
        #expect(source.contains("fn qualifier_example(input: &Input)"))
        // aro_export! generates aro_plugin_qualifier; the qualifier fn must be listed.
        #expect(source.contains("aro_export!"))
        #expect(source.contains("qualifiers: [qualifier_example]"))
        #expect(source.contains("actions: [example]"))
        // The broken pattern must be gone: no hand-rolled info JSON that
        // declared a qualifier without any dispatch.
        #expect(!source.contains("pub extern \"C\" fn aro_plugin_info"))
    }

    @Test("Rust scaffold with qualifiers only leaves the actions list empty")
    func rustQualifiersOnly() throws {
        let source = try generateAndRead(
            language: .rust, file: "src/lib.rs", actions: false)
        #expect(source.contains("qualifiers: [qualifier_example]"))
        #expect(source.contains("actions: []"))
    }

    @Test("The Rust scaffold names only macros the SDK prelude exports (GitLab #549)")
    func rustUsesOnlyExportedMacroNames() throws {
        let source = try generateAndRead(language: .rust, file: "src/lib.rs")

        // `aro_plugin_sdk::prelude` re-exports exactly these three macros:
        //   pub use aro_plugin_sdk_macros::{action, aro_export, qualifier as qualifier_attr};
        // Every macro name the scaffold writes has to be one of them, or the
        // generated crate does not compile — which is how #549 arose, when the
        // scaffold named macros the SDK did not have at all.
        let exportedByPrelude: Set<String> = ["action", "aro_export", "qualifier_attr"]

        // Attribute macros the file applies, as `#[name(`.
        var used: Set<String> = []
        var rest = Substring(source)
        while let open = rest.range(of: "#[") {
            rest = rest[open.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !name.isEmpty { used.insert(String(name)) }
        }
        // Plus the one function-like macro.
        if source.contains("aro_export!") { used.insert("aro_export") }

        #expect(!used.isEmpty, "no macros found — the scan is broken, not the scaffold")
        #expect(used.isSubset(of: exportedByPrelude),
                "scaffold uses macros the prelude does not export: \(used.subtracting(exportedByPrelude).sorted())")
        // Specifically: `#[qualifier]` does not resolve — the SDK has a
        // `qualifier` module, so the attribute is re-exported renamed.
        #expect(!used.contains("qualifier"))
    }

    @Test("The Rust next-steps text names the attribute the scaffold actually writes")
    func rustNextStepsMatchTheTemplate() throws {
        let scaffold = RustPluginScaffold()
        let steps = scaffold.nextSteps(options: options(language: .rust)).joined(separator: "\n")
        let source = try generateAndRead(language: .rust, file: "src/lib.rs")

        // The advice used to say `#[qualifier]`, a name that does not resolve,
        // while the generated file correctly used `#[qualifier_attr]`.
        #expect(steps.contains("#[qualifier_attr]"))
        #expect(source.contains("#[qualifier_attr("))
    }

    // MARK: - C / C++

    // The C templates are asserted via `pluginSource` directly because
    // `generate()` downloads the SDK header from the network.

    @Test("C scaffold wires the example qualifier through ARO_QUALIFIER")
    func cQualifierWiring() {
        let source = CPluginScaffold().pluginSource(
            options: options(language: .c))

        #expect(source.contains("#define ARO_PLUGIN_SDK_IMPLEMENTATION"))
        #expect(source.contains("#include \"aro_plugin_sdk.h\""))
        #expect(source.contains("ARO_PLUGIN(\"greeter\", \"1.0.0\")"))
        #expect(source.contains("ARO_HANDLE(\"Greeter\")"))
        #expect(source.contains("ARO_QUALIFIER(\"example\""))
        #expect(source.contains("ARO_ACTION(\"example\""))
        // The broken pattern must be gone: no hand-rolled aro_plugin_info that
        // never mentioned qualifiers at all.
        #expect(!source.contains("char* aro_plugin_info(void)"))
    }

    @Test("C++ scaffold uses the same SDK macro wiring")
    func cppQualifierWiring() {
        let source = CppPluginScaffold().pluginSource(
            options: options(language: .cpp))
        #expect(source.contains("ARO_QUALIFIER(\"example\""))
        #expect(source.contains("#define ARO_PLUGIN_SDK_IMPLEMENTATION"))
    }
}
