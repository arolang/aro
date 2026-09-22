// ============================================================
// ActionBridgeCoverageTests.swift
// ARO Runtime — every catalog verb has a bridge export
// GitLab #679
// ============================================================
//
// `LLVMCodeGenerator` emits a direct `aro_action_<verb>` call for any verb in
// `ActionCatalog`. GitLab #336 tied the code generator to the catalog; nothing
// tied the catalog to the **exports**, so `touch`, `mkdir` and `rename` — three
// documented aliases of actions that work — turned a valid program into
//
//     Undefined symbols for architecture arm64:
//       "_aro_action_touch", referenced from: …
//
// with no ARO-level diagnostic. A linker error is the worst shape for this:
// `aro check` passes, `aro run` passes, and the failure names a C symbol.
//
// This test is the missing half. It reads the exports out of the built binary
// image rather than a list someone maintains, so an export that is never added
// cannot be declared present.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Action bridge coverage (#679)")
struct ActionBridgeCoverageTests {

    /// Whether `aro_action_<verb>` is a real symbol in this process.
    ///
    /// `dlsym` on the global handle, because that is exactly the question the
    /// linker asks: a shim that compiles but is not exported would still fail
    /// the build of a generated binary.
    private func bridgeExportExists(for verb: String) -> Bool {
        let symbol = "aro_action_\(verb)"
        #if canImport(Darwin)
        let handle = dlopen(nil, RTLD_NOW)
        #else
        let handle = dlopen(nil, RTLD_NOW)
        #endif
        defer { if handle != nil { dlclose(handle) } }
        return dlsym(handle, symbol) != nil
    }

    @Test("Every verb the code generator can emit a call for has an export")
    func everyCatalogVerbIsExported() {
        // `ActionCatalog.allActionVerbs` is what `LLVMCodeGenerator` consults
        // before emitting a direct call, so it is exactly the set that must be
        // exported.
        let missing = ActionCatalog.allActionVerbs
            .filter { !bridgeExportExists(for: $0) }
            .sorted()

        #expect(missing.isEmpty,
                "no aro_action_* export for: \(missing.joined(separator: ", ")) — a program using one of these fails to LINK, not to check")
    }

    @Test("The three verbs that were missing are there")
    func theThreeFromTheIssue() {
        // Named individually so a regression says which one, and so this still
        // means something if the catalog is ever restructured.
        #expect(bridgeExportExists(for: "touch"))
        #expect(bridgeExportExists(for: "mkdir"))
        #expect(bridgeExportExists(for: "rename"))
    }

    @Test("The catalog still lists them, so the generator still emits the calls")
    func catalogStillListsThem() {
        #expect(ActionCatalog.allActionVerbs.contains("touch"))
        #expect(ActionCatalog.allActionVerbs.contains("mkdir"))
        #expect(ActionCatalog.allActionVerbs.contains("rename"))
    }

    @Test("Each alias reaches a registered action")
    func aliasesResolve() {
        // An export that dispatches to nothing would link and then fail at
        // run time, which is only marginally better.
        #expect(ActionRegistry.shared.action(for: "touch") != nil)
        #expect(ActionRegistry.shared.action(for: "mkdir") != nil)
        #expect(ActionRegistry.shared.action(for: "rename") != nil)
    }
}
