// ============================================================
// SnippetLibraryTests.swift
// SOLARO — snippet library, expansion, custom YAML loading (#242)
// ============================================================
//
// The load-bearing test here is `everyBuiltInBodyParses`. A
// snippet that looks like ARO but isn't is the same failure as
// GitLab #486 — plausible, insertable, and wrong — except this
// time we ship it in the IDE. Every built-in goes through the real
// parser, and statement-level snippets get wrapped in a feature
// set first so they're parsed in the position they're used.

import Foundation
import Testing
import AROParser
@testable import SOLARO

@Suite("Snippet library (#242)")
struct SnippetLibraryTests {

    // MARK: - Built-ins are real ARO

    @Test("Every built-in body parses", arguments: AROSnippet.builtIns)
    func everyBuiltInBodyParses(snippet: AROSnippet) throws {
        let expanded = SnippetExpander.expand(snippet.body).text
        let source = snippet.isTopLevel
            ? expanded
            : "(Wrapper: Test Activity) {\n    \(expanded)\n}"
        // Throws on a parse error; the message names the snippet so
        // a failure points at which one to fix.
        do {
            _ = try Parser.parse(source)
        } catch {
            Issue.record("\(snippet.name) does not parse: \(error)\n\(source)")
        }
    }

    @Test("Built-in triggers are unique and typeable")
    func triggersAreWellFormed() {
        var seen = Set<String>()
        for snippet in AROSnippet.builtIns {
            #expect(!snippet.trigger.isEmpty,
                    "\(snippet.name) has no tab trigger")
            #expect(snippet.trigger == snippet.trigger.lowercased())
            let hasWhitespace = snippet.trigger.contains(where: \.isWhitespace)
            #expect(!hasWhitespace, "\(snippet.trigger) is not typeable")
            #expect(seen.insert(snippet.trigger).inserted,
                    "duplicate trigger \(snippet.trigger)")
        }
    }

    @Test("Built-ins describe themselves")
    func builtInsHaveSummaries() {
        for snippet in AROSnippet.builtIns {
            #expect(!snippet.name.isEmpty)
            #expect(!snippet.summary.isEmpty, "\(snippet.name) has no summary")
        }
    }

    @Test("Feature-set snippets are top level, statements are not")
    func topLevelDetection() {
        let routes = AROSnippet.builtIns.first { $0.trigger == "routes" }
        let thrown = AROSnippet.builtIns.first { $0.trigger == "throw" }
        #expect(routes?.isTopLevel == true)
        #expect(thrown?.isTopLevel == false)
    }

    // MARK: - Expansion

    @Test("Expansion strips the token wrappers")
    func expansionStripsWrappers() {
        let out = SnippetExpander.expand("Log \"${message}\" to the <console>.")
        #expect(out.text == "Log \"message\" to the <console>.")
        #expect(!out.text.contains("${"))
    }

    @Test("Placeholder ranges point at the labels")
    func placeholderRangesAreAccurate() throws {
        let out = SnippetExpander.expand("(${Name}: ${Activity}) {")
        #expect(out.placeholders.count == 2)
        let ns = out.text as NSString
        #expect(ns.substring(with: try #require(out.placeholders.first)) == "Name")
        #expect(ns.substring(with: out.placeholders[1]) == "Activity")
        #expect(out.firstPlaceholder == out.placeholders.first)
    }

    @Test("A body without tokens reports no placeholders")
    func noPlaceholders() {
        let out = SnippetExpander.expand("Keepalive the <application> for the <events>.")
        #expect(out.placeholders.isEmpty)
        #expect(out.firstPlaceholder == nil)
    }

    @Test("Indent applies to continuation lines only")
    func indentSkipsFirstLine() {
        let out = SnippetExpander.expand("first\nsecond\nthird", indent: "    ")
        #expect(out.text == "first\n    second\n    third")
    }

    @Test("Blank lines stay blank when indenting")
    func indentLeavesBlankLinesAlone() {
        let out = SnippetExpander.expand("a\n\nb", indent: "  ")
        #expect(out.text == "a\n\n  b")
    }

    @Test("Placeholder ranges survive indentation")
    func placeholdersAfterIndent() throws {
        let out = SnippetExpander.expand("a\n${label} tail", indent: "  ")
        #expect(out.text == "a\n  label tail")
        let ns = out.text as NSString
        #expect(ns.substring(with: try #require(out.firstPlaceholder)) == "label")
    }

    @Test("An unterminated token is left as written")
    func unterminatedTokenIsLiteral() {
        // No closing brace — better to insert the text verbatim than
        // to swallow the rest of the snippet.
        let out = SnippetExpander.expand("Log ${oops to the <console>.")
        #expect(out.text == "Log ${oops to the <console>.")
        #expect(out.placeholders.isEmpty)
    }

    // MARK: - Custom snippet files

    @Test("Decodes the snippets: mapping form")
    func decodesMappingForm() throws {
        let yaml = """
        snippets:
          - name: Log line
            description: Write to the console
            trigger: logline
            body: |
              Log "${message}" to the <console>.
        """
        let out = try SnippetFileDecoder.decode(yaml: yaml, fileName: "team.yaml")
        #expect(out.count == 1)
        #expect(out[0].name == "Log line")
        #expect(out[0].trigger == "logline")
        #expect(out[0].origin == .custom(fileName: "team.yaml"))
        // The block scalar's trailing newline is a YAML artefact.
        #expect(out[0].body == "Log \"${message}\" to the <console>.")
    }

    @Test("Decodes a bare list")
    func decodesBareList() throws {
        let yaml = """
        - name: Bare
          body: Log "hi" to the <console>.
        """
        let out = try SnippetFileDecoder.decode(yaml: yaml, fileName: "bare.yaml")
        #expect(out.count == 1)
        #expect(out[0].summary.isEmpty)
        #expect(out[0].trigger.isEmpty)
    }

    @Test("An empty file decodes to nothing")
    func decodesEmptyFile() throws {
        #expect(try SnippetFileDecoder.decode(yaml: "", fileName: "e.yaml").isEmpty)
    }

    @Test("Triggers are lowercased and trimmed on load")
    func normalisesTrigger() throws {
        let yaml = """
        - name: Shouty
          trigger: "  ROUTES  "
          body: Log "x" to the <console>.
        """
        let out = try SnippetFileDecoder.decode(yaml: yaml, fileName: "s.yaml")
        #expect(out[0].trigger == "routes")
    }

    @Test("A nameless entry is an error naming the file")
    func missingNameIsAnError() {
        let yaml = "- body: Log \"x\" to the <console>."
        #expect(throws: SnippetError.self) {
            try SnippetFileDecoder.decode(yaml: yaml, fileName: "broken.yaml")
        }
    }

    @Test("A bodyless entry is an error naming the snippet")
    func missingBodyIsAnError() {
        let yaml = "- name: Empty"
        do {
            _ = try SnippetFileDecoder.decode(yaml: yaml, fileName: "broken.yaml")
            Issue.record("expected a throw")
        } catch {
            #expect("\(error)".contains("Empty"))
            #expect("\(error)".contains("broken.yaml"))
        }
    }

    @Test("A scalar document is rejected with a readable message")
    func scalarDocumentIsAnError() {
        #expect(throws: SnippetError.self) {
            try SnippetFileDecoder.decode(yaml: "just a string", fileName: "x.yaml")
        }
    }

    // MARK: - Splicing into a buffer

    @Test("A Tab trigger is replaced, not inserted next to")
    func triggerIsConsumed() throws {
        let source = "(F: A) {\n    log\n}\n"
        // Caret sits right after "log" on line 2 (column 7).
        let out = try #require(SnippetSplice.apply(
            body: "Log \"${message}\" to the <console>.",
            to: source, line: 2, column: 7, replacingTrigger: "log"))
        #expect(out.text == "(F: A) {\n    Log \"message\" to the <console>.\n}\n")
        #expect(!out.text.contains("logLog"))
    }

    @Test("A trigger that isn't actually there inserts at the caret")
    func triggerMismatchStillInserts() throws {
        let source = "(F: A) {\n    \n}\n"
        let out = try #require(SnippetSplice.apply(
            body: "Keepalive the <application> for the <events>.",
            to: source, line: 2, column: 4, replacingTrigger: "routes"))
        #expect(out.text.contains("    Keepalive the <application>"))
    }

    @Test("Continuation lines pick up the caret line's indentation")
    func spliceIndentsContinuationLines() throws {
        let source = "(F: A) {\n    \n}\n"
        let out = try #require(SnippetSplice.apply(
            body: "one\ntwo", to: source, line: 2, column: 4))
        #expect(out.text == "(F: A) {\n    one\n    two\n}\n")
    }

    @Test("Selection lands on the first placeholder in the new buffer")
    func spliceSelectionIsAbsolute() throws {
        let source = "(F: A) {\n    \n}\n"
        let out = try #require(SnippetSplice.apply(
            body: "Log \"${message}\" to the <console>.",
            to: source, line: 2, column: 4))
        let selection = try #require(out.selection)
        #expect((out.text as NSString).substring(with: selection) == "message")
    }

    @Test("Without placeholders the caret lands past the insertion")
    func spliceCaretOffset() throws {
        let source = "(F: A) {\n    \n}\n"
        let body = "Keepalive the <application> for the <events>."
        let out = try #require(SnippetSplice.apply(
            body: body, to: source, line: 2, column: 4))
        #expect(out.selection == nil)
        #expect(out.caretOffset == 13 + (body as NSString).length)
        // 13 = "(F: A) {\n" (9) + four spaces of indent.
    }

    @Test("A line past the end of the buffer splices nothing")
    func spliceOutOfRange() {
        #expect(SnippetSplice.apply(
            body: "x", to: "one line\n", line: 99, column: 0) == nil)
        #expect(SnippetSplice.apply(
            body: "x", to: "one line\n", line: 0, column: 0) == nil)
    }

    @Test("A column past the end of the line clamps to it")
    func spliceColumnClamps() throws {
        let out = try #require(SnippetSplice.apply(
            body: "!", to: "abc\ndef\n", line: 1, column: 99))
        #expect(out.text == "abc!\ndef\n")
    }

    @Test("Every built-in splices into a feature set cleanly")
    func builtInsSpliceAndStillParse() throws {
        for snippet in AROSnippet.builtIns where !snippet.isTopLevel {
            let source = "(Wrapper: Test Activity) {\n    \n}\n"
            let out = try #require(SnippetSplice.apply(
                body: snippet.body, to: source, line: 2, column: 4))
            _ = try Parser.parse(out.text)
        }
    }

    // MARK: - Library

    @MainActor
    @Test("With no project the library is the built-ins")
    func libraryWithoutProject() {
        let library = SnippetLibrary()
        library.reload(projectRoot: nil)
        #expect(library.custom.isEmpty)
        #expect(library.all.count == AROSnippet.builtIns.count)
        #expect(library.loadError == nil)
    }

    @MainActor
    @Test("Custom snippets load and override a built-in trigger")
    func customOverridesBuiltIn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solaro-snippets-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(SnippetLibrary.customDirectory)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        snippets:
          - name: House route triple
            description: Ours, not the shipped one
            trigger: routes
            body: |
              Log "house style" to the <console>.
        """.write(to: dir.appendingPathComponent("house.yaml"),
                  atomically: true, encoding: .utf8)

        let library = SnippetLibrary()
        library.reload(projectRoot: root)
        #expect(library.loadError == nil)
        #expect(library.custom.count == 1)
        // Custom first: the panel lists the project's own on top.
        #expect(library.all.first?.name == "House route triple")
        #expect(library.snippet(forTrigger: "routes")?.name == "House route triple")
        // A built-in trigger nobody overrode still resolves.
        #expect(library.snippet(forTrigger: "observer")?.origin == .builtIn)
        #expect(library.snippet(forTrigger: "") == nil)
        #expect(library.snippet(forTrigger: "nope") == nil)
    }

    @MainActor
    @Test("One broken file reports an error and keeps the good ones")
    func brokenFileDoesNotEmptyThePanel() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solaro-snippets-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(SnippetLibrary.customDirectory)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "- name: Good\n  body: Log \"ok\" to the <console>."
            .write(to: dir.appendingPathComponent("a-good.yaml"),
                   atomically: true, encoding: .utf8)
        try "- body: no name here"
            .write(to: dir.appendingPathComponent("b-broken.yaml"),
                   atomically: true, encoding: .utf8)

        let library = SnippetLibrary()
        library.reload(projectRoot: root)
        #expect(library.custom.count == 1)
        #expect(library.custom.first?.name == "Good")
        #expect(library.loadError != nil)
        #expect(library.loadError?.contains("b-broken.yaml") == true)
    }

    @MainActor
    @Test("Reloading against a project without the folder clears state")
    func reloadClearsPreviousProject() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("solaro-snippets-\(UUID().uuidString)")
        let dir = root.appendingPathComponent(SnippetLibrary.customDirectory)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "- name: Only\n  body: Log \"x\" to the <console>."
            .write(to: dir.appendingPathComponent("s.yaml"),
                   atomically: true, encoding: .utf8)

        let library = SnippetLibrary()
        library.reload(projectRoot: root)
        #expect(library.custom.count == 1)

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("solaro-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        library.reload(projectRoot: empty)
        #expect(library.custom.isEmpty)
        #expect(library.loadError == nil)
    }
}
