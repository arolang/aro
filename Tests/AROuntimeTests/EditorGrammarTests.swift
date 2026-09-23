// ============================================================
// EditorGrammarTests.swift
// The editor grammars must match the action registry (GitLab #695)
// ============================================================

import Testing
import Foundation
@testable import ARORuntime

/// The VS Code and IntelliJ TextMate grammars used to be hand-maintained verb
/// lists, and had drifted to 67 of the runtime's 130 verbs — with none of
/// ARO-0080's Git verbs in any of them, and two invented ones (`Parameters`,
/// `Watch`) that no action implements. They are generated now
/// (`Scripts/generate-editor-grammars.py`), and CI runs that script with
/// `--check`.
///
/// These tests assert the property directly rather than re-running the
/// generator, so `swift test` fails on drift even when the script is not run:
/// every registered verb is highlighted, nothing is highlighted that is not a
/// verb, and the IntelliJ bundle really is a copy rather than a third opinion.
@Suite("Editor Grammar Parity")
struct EditorGrammarTests {

    /// Repo root, derived from this file's location:
    /// Tests/AROuntimeTests/EditorGrammarTests.swift -> three levels up.
    private static func repoRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // AROuntimeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private static let canonicalPath = "Editor/vscode-aro/syntaxes/aro.tmLanguage.json"
    private static let bundlePath =
        "Editor/intellij-aro/src/main/resources/textmate/aro-bundle/syntaxes/aro.tmLanguage.json"

    /// The verbs named by the grammar's `repository.actions` patterns.
    private func grammarVerbs() throws -> Set<String> {
        let url = Self.repoRoot().appendingPathComponent(Self.canonicalPath)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let repository = json?["repository"] as? [String: Any]
        let actions = repository?["actions"] as? [String: Any]
        let patterns = actions?["patterns"] as? [[String: Any]] ?? []

        var verbs: Set<String> = []
        for pattern in patterns {
            guard let match = pattern["match"] as? String else { continue }
            // Every generated pattern is `\b(A|B|C)\b`.
            guard let open = match.firstIndex(of: "("),
                  let close = match.lastIndex(of: ")") else { continue }
            let body = match[match.index(after: open)..<close]
            for name in body.split(separator: "|") {
                verbs.insert(String(name))
            }
        }
        return verbs
    }

    /// Built-in verbs only. A grammar ships with the editor and cannot know
    /// about an application's plugin actions — and the shared registry is
    /// process-wide, so a sibling test that registers a plugin verb would
    /// otherwise make this suite fail depending on run order.
    private func runtimeVerbs() -> Set<String> {
        AROCatalog.actionsSnapshot()
            .filter { $0.origin == .builtin }
            .reduce(into: Set<String>()) { $0.insert($1.verb.lowercased()) }
    }

    @Test("Every registered action verb is in the grammar")
    func testEveryVerbIsHighlighted() throws {
        let grammar = Set(try grammarVerbs().map { $0.lowercased() })
        let runtime = runtimeVerbs()

        // Guard against a vacuous pass: an empty registry or an unparsed
        // grammar would make "nothing is missing" trivially true.
        #expect(runtime.count > 100)
        #expect(grammar.count > 100)

        let missing = runtime.subtracting(grammar).sorted()

        #expect(
            missing.isEmpty,
            "the grammar does not highlight \(missing.count) registered verbs: \(missing.joined(separator: ", "))"
        )
    }

    @Test("The Git verbs from ARO-0080 are highlighted")
    func testGitVerbsPresent() throws {
        // Named explicitly because their absence is what the issue reported:
        // a whole proposal's worth of syntax rendered as prose.
        let grammar = Set(try grammarVerbs().map { $0.lowercased() })
        for verb in ["stage", "commit", "pull", "push", "clone", "checkout", "tag"] {
            #expect(grammar.contains(verb), "grammar is missing the Git verb '\(verb)'")
        }
    }

    @Test("The grammar highlights nothing the runtime does not implement")
    func testNoInventedVerbs() throws {
        let runtime = runtimeVerbs()
        let invented = try grammarVerbs()
            .filter { !runtime.contains($0.lowercased()) }
            .sorted()

        // `Parameters` and `Watch` were both listed and neither exists.
        #expect(
            invented.isEmpty,
            "the grammar highlights \(invented.count) words no action implements: \(invented.joined(separator: ", "))"
        )
    }

    @Test("The IntelliJ bundle is a copy of the canonical grammar")
    func testIntelliJBundleIsACopy() throws {
        let root = Self.repoRoot()
        let canonical = try Data(contentsOf: root.appendingPathComponent(Self.canonicalPath))
        let bundle = try Data(contentsOf: root.appendingPathComponent(Self.bundlePath))

        #expect(
            canonical == bundle,
            "the IntelliJ grammar has drifted from the canonical one — run python3 Scripts/generate-editor-grammars.py"
        )
    }

    @Test("There is no second, unread IntelliJ grammar")
    func testNoStrayIntelliJGrammar() {
        // `AROTextMateBundleProvider` only ever reads the aro-bundle path; a
        // grammar beside it is a copy nobody loads and everybody edits.
        let stray = Self.repoRoot()
            .appendingPathComponent("Editor/intellij-aro/src/main/resources/textmate/aro.tmLanguage.json")

        #expect(!FileManager.default.fileExists(atPath: stray.path))
    }
}
