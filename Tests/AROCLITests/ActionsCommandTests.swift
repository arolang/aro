// ============================================================
// ActionsCommandTests.swift
// ARO CLI - `aro actions` discoverability (GitLab #483)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

/// `aro actions` printed only canonical names, roles and prepositions. Verb
/// aliases were omitted, so the spellings users actually write were invisible:
/// `CreateDirectory` and `Keepalive` both appear in this project's examples and
/// in CLAUDE.md, and neither could be found with the command whose job is to
/// list actions (GitLab #483).
///
/// The command itself is thin formatting over `ActionRegistry`; these tests
/// cover the registry data it depends on, so a regression that empties the verb
/// lists or breaks alias resolution is caught.
@Suite("Actions Catalog Data")
struct ActionsCatalogDataTests {

    private var builtIns: [ActionRegistry.BuiltInActionInfo] {
        ActionRegistry.shared.allBuiltInActionInfos
    }

    /// Mirrors the command's resolution: canonical name or any verb alias.
    private func lookUp(_ query: String) -> ActionRegistry.BuiltInActionInfo? {
        let needle = query.lowercased()
        return builtIns.first {
            $0.name.lowercased() == needle || $0.verbs.contains { $0.lowercased() == needle }
        }
    }

    @Test("Every action reports at least one verb")
    func testEveryActionHasVerbs() {
        let verbless = builtIns.filter(\.verbs.isEmpty).map(\.name)

        #expect(verbless.isEmpty, "actions with no verbs: \(verbless)")
    }

    @Test("CreateDirectory resolves to Make")
    func testCreateDirectoryResolves() throws {
        // The exact case from the issue: used in Examples/FileOperations, and
        // previously unfindable via `aro actions`.
        let action = try #require(lookUp("createdirectory"))

        #expect(action.name == "Make")
        #expect(action.verbs.contains("createdirectory"))
    }

    @Test("Keepalive resolves to its canonical action")
    func testKeepaliveResolves() throws {
        // Used in CLAUDE.md and Examples/HTTPServer.
        let action = try #require(lookUp("keepalive"))

        #expect(action.verbs.contains("keepalive"))
        #expect(action.prepositions.contains("for"))
    }

    @Test("Other documented aliases resolve")
    func testOtherAliasesResolve() throws {
        let cases: [(alias: String, canonical: String)] = [
            ("print", "Log"),
            ("fetch", "Retrieve"),
            ("exec", "Execute"),
            ("mkdir", "Make"),
        ]
        for (alias, canonical) in cases {
            let action = try #require(lookUp(alias), "alias '\(alias)' did not resolve")
            #expect(action.name == canonical, "'\(alias)' -> \(action.name), expected \(canonical)")
        }
    }

    @Test("Lookup by canonical name works")
    func testCanonicalLookup() throws {
        #expect(lookUp("Log")?.name == "Log")
        #expect(lookUp("log")?.name == "Log")
        #expect(lookUp("LOG")?.name == "Log")
    }

    @Test("An unknown name resolves to nothing")
    func testUnknownLookup() {
        #expect(lookUp("zzz-not-an-action") == nil)
    }

    @Test("Every catalogued verb resolves back to an action")
    func testEveryVerbIsResolvable() {
        var unresolvable: [String] = []
        for action in builtIns {
            for verb in action.verbs where lookUp(verb) == nil {
                unresolvable.append("\(action.name).\(verb)")
            }
        }

        #expect(unresolvable.isEmpty, "verbs that do not resolve: \(unresolvable)")
    }

    @Test("The catalog is JSON-serialisable")
    func testJSONSerialisable() throws {
        // The command's --format json path builds this shape; if a field stops
        // being representable the CLI would silently print an error instead.
        let payload: [String: Any] = [
            "builtin": builtIns.map { action in
                [
                    "name": action.name,
                    "role": action.role.rawValue,
                    "verbs": action.verbs.sorted(),
                    "prepositions": action.prepositions.sorted()
                ] as [String: Any]
            }
        ]

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let actions = try #require(decoded?["builtin"] as? [[String: Any]])

        #expect(actions.count == builtIns.count)
        #expect(actions.allSatisfy { ($0["verbs"] as? [String])?.isEmpty == false })
    }
}
