// ============================================================
// TemplateEscapingTests.swift
// ARO Runtime - Template output escaping (GitLab #476)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime

@Suite("Template Escaping Mode Selection")
struct TemplateEscapingModeTests {

    @Test("HTML extensions select HTML escaping")
    func testHTMLExtensions() {
        #expect(TemplateEscaping.forTemplate(path: "page.html") == .html)
        #expect(TemplateEscaping.forTemplate(path: "page.htm") == .html)
        #expect(TemplateEscaping.forTemplate(path: "views/user-list.HTML") == .html)
        #expect(TemplateEscaping.forTemplate(path: "/abs/path/layout.html") == .html)
    }

    @Test("Non-HTML extensions select no escaping")
    func testNonHTMLExtensions() {
        // Plain-text templates, emails and terminal output must pass through:
        // escaping them would corrupt the output.
        #expect(TemplateEscaping.forTemplate(path: "welcome.tpl") == .none)
        #expect(TemplateEscaping.forTemplate(path: "note.txt") == .none)
        #expect(TemplateEscaping.forTemplate(path: "report.md") == .none)
        #expect(TemplateEscaping.forTemplate(path: "data.json") == .none)
        #expect(TemplateEscaping.forTemplate(path: "noextension") == .none)
    }

    @Test("A path merely containing 'html' is not treated as HTML")
    func testHTMLSubstringIsNotEnough() {
        #expect(TemplateEscaping.forTemplate(path: "html/report.txt") == .none)
        #expect(TemplateEscaping.forTemplate(path: "htmlish.tpl") == .none)
    }

    @Test("Applying .none is the identity")
    func testNoneIsIdentity() {
        let input = "<script>alert(1)</script> & \"quotes\""

        #expect(TemplateEscaping.none.apply(to: input) == input)
    }

    @Test("Applying .html escapes markup")
    func testHTMLEscapes() {
        #expect(
            TemplateEscaping.html.apply(to: "<script>alert(1)</script>")
                == "&lt;script&gt;alert(1)&lt;/script&gt;"
        )
    }

    @Test("The raw qualifier is recognised case-insensitively")
    func testRawQualifier() {
        #expect(TemplateEscaping.isRawQualifier("raw"))
        #expect(TemplateEscaping.isRawQualifier("RAW"))
        #expect(!TemplateEscaping.isRawQualifier("rawish"))
        #expect(!TemplateEscaping.isRawQualifier("error"))
    }
}

@Suite("Template Escaping End To End")
struct TemplateEscapingEndToEndTests {

    /// Renders `templateBody` written to a file with `filename`, with `bindings`
    /// available to the template, and returns the rendered output.
    private func render(
        filename: String,
        templateBody: String,
        bindings: [String: any Sendable]
    ) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-476-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent(filename)
        try Data(templateBody.utf8).write(to: path)

        let parsed = try TemplateParser().parse(templateBody, path: path.lastPathComponent)

        let eventBus = EventBus()
        let context = RuntimeContext(featureSetName: "Test", eventBus: eventBus)
        for (name, value) in bindings {
            context.bind(name, value: value)
        }

        let service = AROTemplateService(templatesDirectory: dir.path)
        context.register(service as any TemplateService)

        let executor = TemplateExecutor(actionRegistry: .shared, eventBus: eventBus)
        return try await executor.render(
            template: parsed,
            context: context,
            templateService: service
        )
    }

    @Test("Values are HTML-escaped in an .html template")
    func testEscapedInHTMLTemplate() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "<h1>{{ Print <name> to the <template>. }}</h1>",
            bindings: ["name": "<script>alert(1)</script>"]
        )

        #expect(output.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!output.contains("<script>"))
    }

    @Test("Values pass through unescaped in a .txt template")
    func testNotEscapedInTextTemplate() async throws {
        let output = try await render(
            filename: "note.txt",
            templateBody: "Plain: {{ Print <name> to the <template>. }}",
            bindings: ["name": "<b>bold</b> & more"]
        )

        #expect(output.contains("<b>bold</b> & more"))
    }

    @Test("<template: raw> opts a value out of escaping")
    func testRawOptOut() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "<div>{{ Print <markup> to the <template: raw>. }}</div>",
            bindings: ["markup": "<b>bold</b>"]
        )

        #expect(output.contains("<b>bold</b>"))
        #expect(!output.contains("&lt;b&gt;"))
    }

    @Test("Escaped and raw values coexist in one template")
    func testMixedEscapingInOneTemplate() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: """
            <h1>{{ Print <name> to the <template>. }}</h1>
            <div>{{ Print <markup> to the <template: raw>. }}</div>
            """,
            bindings: ["name": "<script>x</script>", "markup": "<b>ok</b>"]
        )

        #expect(output.contains("&lt;script&gt;x&lt;/script&gt;"))
        #expect(output.contains("<b>ok</b>"))
    }

    @Test("Static template text is never escaped")
    func testStaticTextUntouched() async throws {
        // Only interpolated values are escaped — the template's own markup is
        // authored content and must survive verbatim.
        let output = try await render(
            filename: "page.html",
            templateBody: #"<a href="/x?a=1&b=2">link</a>{{ Print <name> to the <template>. }}"#,
            bindings: ["name": "plain"]
        )

        #expect(output.contains(#"<a href="/x?a=1&b=2">link</a>"#))
    }

    @Test("An attribute-breaking value cannot escape its quotes")
    func testAttributeBreakoutPrevented() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: #"<img alt="{{ Print <alt> to the <template>. }}">"#,
            bindings: ["alt": #"" onerror="evil()"#]
        )

        // Exactly the two quotes the template itself wrote.
        #expect(output.filter { $0 == "\"" }.count == 2)
        #expect(!output.contains("onerror=\""))
    }
}

// MARK: - The `{{ <x> }}` shorthand (GitLab #560)

/// ARO-0050 §3 and Chapter 44 §44.3 both describe `{{ <x> }}` as *equivalent*
/// to `{{ Print <x> to the <template>. }}`. The escaping #476 installed was
/// applied by the Print path only, so the shorthand wrote its value through
/// unescaped — and the shorthand is the form every example in the book and the
/// proposal reaches for first. The short path was the unsafe one, which is the
/// exact inversion #476 set out to fix.
@Suite("Template shorthand escaping (GitLab #560)")
struct TemplateShorthandEscapingTests {

    private func render(
        filename: String,
        templateBody: String,
        bindings: [String: any Sendable]
    ) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-560-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent(filename)
        try Data(templateBody.utf8).write(to: path)
        let parsed = try TemplateParser().parse(templateBody, path: path.lastPathComponent)

        let eventBus = EventBus()
        let context = RuntimeContext(featureSetName: "Test", eventBus: eventBus)
        for (name, value) in bindings { context.bind(name, value: value) }

        let service = AROTemplateService(templatesDirectory: dir.path)
        context.register(service as any TemplateService)

        let executor = TemplateExecutor(actionRegistry: .shared, eventBus: eventBus)
        return try await executor.render(template: parsed, context: context, templateService: service)
    }

    // MARK: - The bug

    @Test("The shorthand is escaped in an .html template")
    func shorthandIsEscaped() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "<h1>{{ <name> }}</h1>",
            bindings: ["name": "<script>alert(1)</script>"]
        )

        #expect(output.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(!output.contains("<script>"))
    }

    @Test("The shorthand and the Print form agree, which is what the docs promise")
    func shorthandMatchesPrint() async throws {
        let shorthand = try await render(
            filename: "page.html",
            templateBody: "{{ <name> }}",
            bindings: ["name": "Alice <b>"]
        )
        let printed = try await render(
            filename: "page.html",
            templateBody: "{{ Print <name> to the <template>. }}",
            bindings: ["name": "Alice <b>"]
        )

        #expect(shorthand == printed)
        #expect(shorthand.contains("Alice &lt;b&gt;"))
    }

    @Test("A qualified field through the shorthand is escaped too")
    func qualifiedFieldIsEscaped() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "{{ <user: name> }}",
            bindings: ["user": ["name": "Alice <b>"] as [String: any Sendable]]
        )

        #expect(output.contains("Alice &lt;b&gt;"))
        #expect(!output.contains("<b>"))
    }

    // MARK: - The opt-out

    @Test("`| raw` opts the shorthand out, as <template: raw> does for Print")
    func rawFilterOptsOut() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "<div>{{ <markup> | raw }}</div>",
            bindings: ["markup": "<b>bold</b>"]
        )

        #expect(output.contains("<b>bold</b>"))
    }

    @Test("`raw` is not passed on to the filter pipeline as an unknown filter")
    func rawIsConsumed() async throws {
        // It is an escaping directive, not a value transform: the value must
        // come through untouched rather than gaining a "raw" rendering.
        let output = try await render(
            filename: "page.html",
            templateBody: "{{ <markup> | raw }}",
            bindings: ["markup": "<b>x</b>"]
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "<b>x</b>")
    }

    @Test("`raw` composes with a real filter and still suppresses escaping")
    func rawComposesWithAFilter() async throws {
        let output = try await render(
            filename: "page.html",
            templateBody: "{{ <name> | uppercase | raw }}",
            bindings: ["name": "<b>x</b>"]
        )
        #expect(output.contains("<B>X</B>"))
    }

    // MARK: - Non-escaping formats are untouched

    @Test("A .tpl template still passes the shorthand through")
    func tplIsUnescaped() async throws {
        // `.tpl`, `.txt` and `.md` do not escape (#476) — a `.tpl` emitting
        // HTML still needs `html-escape`, which this must not change.
        let output = try await render(
            filename: "note.tpl",
            templateBody: "Plain: {{ <name> }}",
            bindings: ["name": "<b>bold</b> & more"]
        )
        #expect(output.contains("<b>bold</b> & more"))
    }

    @Test("A .screen template passes ANSI and markup through")
    func screenIsUnescaped() async throws {
        // Terminal templates must not be escaped; escaping would corrupt them.
        let output = try await render(
            filename: "menu.screen",
            templateBody: "{{ <label> }}",
            bindings: ["label": "<ok> & done"]
        )
        #expect(output.contains("<ok> & done"))
    }

    @Test("A filter's output is escaped unless raw is asked for")
    func filterOutputIsEscaped() async throws {
        // Escaping runs after the filters, exactly as Print escapes its
        // finished message — so `markdown`, which deliberately emits HTML,
        // needs `| raw` in an .html template. Safe by default.
        let output = try await render(
            filename: "page.html",
            templateBody: "{{ <text> | uppercase }}",
            bindings: ["text": "<b>hi</b>"]
        )
        #expect(output.contains("&lt;B&gt;HI&lt;/B&gt;"))
    }
}
