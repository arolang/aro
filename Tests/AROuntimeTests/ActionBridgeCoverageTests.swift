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
// This test is the missing half, and it reads the `@_cdecl` declarations out of
// the bridge sources rather than out of the running image.
//
// `dlsym` was the obvious way to ask and it is the wrong one. ARORuntime is
// linked into the test binary as a static archive, and on Linux an executable's
// static symbols do not reach `.dynsym` without `-rdynamic` — so `dlopen(nil)`
// plus `dlsym` found *every* verb missing there while finding all of them on
// macOS. A check that answers "all present" on one platform and "none present"
// on another is not checking anything.
//
// The declaration is also the right thing to assert: it is what the linker
// resolves a generated call against, and it is what someone adding an action
// forgets to write.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Action bridge coverage (#679)")
struct ActionBridgeCoverageTests {

    /// Every `aro_action_<verb>` exported from the bridge sources.
    ///
    /// Located from `#filePath` rather than the working directory, which the
    /// test runner does not promise.
    private static let exportedVerbs: Set<String> = {
        let bridge = URL(fileURLWithPath: #filePath)     // …/Tests/AROuntimeTests/this
            .deletingLastPathComponent()                  // …/Tests/AROuntimeTests
            .deletingLastPathComponent()                  // …/Tests
            .deletingLastPathComponent()                  // repo root
            .appendingPathComponent("Sources/ARORuntime/Bridge")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bridge, includingPropertiesForKeys: nil) else { return [] }

        var found: Set<String> = []
        let pattern = try! NSRegularExpression(pattern: #"@_cdecl\("aro_action_([a-z0-9_]+)"\)"#)

        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    found.insert(String(text[r]))
                }
            }
        }
        return found
    }()

    @Test("The bridge sources were actually found")
    func sourcesAreReachable() {
        // Everything below is vacuously true against an empty set, which is
        // exactly how this test would rot into meaninglessness if the layout
        // moved. 245 exports live in that directory; a handful means a broken
        // path, not a stripped bridge.
        #expect(Self.exportedVerbs.count > 50,
                "found only \(Self.exportedVerbs.count) aro_action_* declarations — check the path to Sources/ARORuntime/Bridge")
    }

    @Test("Every verb the code generator can emit a call for has an export")
    func everyCatalogVerbIsExported() {
        // `ActionCatalog.allActionVerbs` is what `LLVMCodeGenerator` consults
        // before emitting a direct call, so it is exactly the set that must be
        // exported.
        let missing = ActionCatalog.allActionVerbs
            .filter { !Self.exportedVerbs.contains($0) }
            .sorted()

        #expect(missing.isEmpty,
                "no aro_action_* export for: \(missing.joined(separator: ", ")) — a program using one of these fails to LINK, not to check")
    }

    @Test("The three verbs that were missing are there")
    func theThreeFromTheIssue() {
        // Named individually so a regression says which one, and so this still
        // means something if the catalog is ever restructured.
        #expect(Self.exportedVerbs.contains("touch"))
        #expect(Self.exportedVerbs.contains("mkdir"))
        #expect(Self.exportedVerbs.contains("rename"))
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
        // run time, which is only marginally better. This one *is* a runtime
        // question, and the registry answers it identically on both platforms.
        #expect(ActionRegistry.shared.action(for: "touch") != nil)
        #expect(ActionRegistry.shared.action(for: "mkdir") != nil)
        #expect(ActionRegistry.shared.action(for: "rename") != nil)
    }
}
