// ============================================================
// PluginDocsHTMLEscapingTests.swift
// ARO CLI Tests — `aro plugins docs --html` escapes plugin metadata
// (GitLab #741)
// ============================================================

import Testing
import Foundation
@testable import AROCLI

/// Everything `aro plugins docs --html` renders comes from a third party: the
/// plugin's `plugin.yaml` and the JSON its `aro_plugin_info()` returns. Only the
/// `description` fields were escaped, so an action named `<script>…`, a verb
/// carrying a quote, a service name, a capability or the namespace handle went
/// into the generated page verbatim — and the page is something the user then
/// opens in a browser.
@Suite("Plugin docs HTML escaping (#741)")
struct PluginDocsHTMLEscapingTests {

    /// The payload used throughout: markup, both quote characters, and an
    /// ampersand that must not be double-escaped.
    static let hostile = #"<script>alert('x')</script> & "quoted""#

    static let hostileEscaped =
        "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quoted&quot;"

    // MARK: - The escaper itself

    @Test("Escapes all five HTML-significant characters")
    func escapesAllFive() {
        #expect(DocsPlugins.htmlEscape(Self.hostile) == Self.hostileEscaped)
        #expect(DocsPlugins.htmlEscape("&") == "&amp;")
        #expect(DocsPlugins.htmlEscape("<") == "&lt;")
        #expect(DocsPlugins.htmlEscape(">") == "&gt;")
        #expect(DocsPlugins.htmlEscape("\"") == "&quot;")
        #expect(DocsPlugins.htmlEscape("'") == "&#39;")
    }

    @Test("Ampersands introduced by escaping are not escaped again")
    func noDoubleEscaping() {
        #expect(DocsPlugins.htmlEscape("&<") == "&amp;&lt;")
        #expect(DocsPlugins.htmlEscape("a &amp; b") == "a &amp;amp; b")
    }

    @Test("Text without special characters is returned unchanged")
    func plainTextUnchanged() {
        #expect(DocsPlugins.htmlEscape("pick-random") == "pick-random")
        #expect(DocsPlugins.htmlEscape("") == "")
    }

    // MARK: - The generated page

    /// A manifest and plugin info in which *every* string a plugin controls
    /// carries the hostile payload.
    private func hostilePage() -> String {
        let metadata = DocsPlugins.BasicManifest(
            name: "plugin\(Self.hostile)",
            version: "1.0.0\(Self.hostile)",
            description: "desc \(Self.hostile)",
            author: "author \(Self.hostile)",
            license: "MIT \(Self.hostile)",
            handle: "Handle\(Self.hostile)"
        )

        var info = DocsPlugins.PluginDocInfo()
        info.actions = [
            DocsPlugins.ActionDoc(
                name: "Action\(Self.hostile)",
                verbs: ["Verb\(Self.hostile)"],
                role: "own \(Self.hostile)",
                prepositions: ["with \(Self.hostile)"],
                description: "action desc \(Self.hostile)",
                since: "1.0 \(Self.hostile)"
            )
        ]
        info.qualifiers = [
            DocsPlugins.QualifierDoc(
                name: "qual\(Self.hostile)",
                inputTypes: ["List\(Self.hostile)"],
                description: "qual desc \(Self.hostile)",
                acceptsParameters: true
            )
        ]
        info.services = [
            DocsPlugins.ServiceDoc(
                name: "Service\(Self.hostile)",
                methods: ["method\(Self.hostile)"]
            )
        ]
        info.systemObjects = [
            DocsPlugins.SystemObjectDoc(
                identifier: "object\(Self.hostile)",
                capabilities: ["cap\(Self.hostile)"],
                description: "object desc \(Self.hostile)"
            )
        ]
        info.events = ["Event\(Self.hostile)"]

        return DocsPlugins.generateHTML(metadata: metadata, info: info)
    }

    @Test("No plugin-supplied markup reaches the page")
    func noRawMarkupInPage() {
        let html = hostilePage()
        // The literal payload must appear nowhere — not in the title, the
        // heading, a verb, a service name, a capability or the handle.
        #expect(!html.contains("<script>"))
        #expect(!html.contains("</script>"))
        #expect(!html.contains("alert('x')"))
        #expect(!html.contains(#""quoted""#))
    }

    @Test("Every plugin-supplied field is present in escaped form")
    func everyFieldIsEscaped() {
        let html = hostilePage()
        // The payload is attached to 21 distinct values above (name, version,
        // description, author, license, handle, and every action, qualifier,
        // service, system-object and event field). Each must appear, and appear
        // escaped — a value dropped from the page would pass the "no raw
        // markup" test just as well as a value that is escaped.
        let escapedCount = html.components(separatedBy: Self.hostileEscaped).count - 1
        #expect(escapedCount >= 21, "expected the escaped payload throughout, saw \(escapedCount)")
    }

    @Test("The badge's single-quoted attribute cannot be broken out of")
    func singleQuotesAreEscaped() {
        let html = hostilePage()
        // The page writes `class='badge'`, so an unescaped apostrophe in an
        // adjacent value is an attribute-injection point.
        #expect(html.contains("&#39;"))
        #expect(html.contains("<span class='badge'>params</span>"))
    }

    @Test("A benign plugin still renders readable documentation")
    func benignPluginRendersNormally() {
        let metadata = DocsPlugins.BasicManifest(
            name: "plugin-collection",
            version: "1.2.0",
            description: "Collection helpers",
            handle: "Collections"
        )
        var info = DocsPlugins.PluginDocInfo()
        info.qualifiers = [
            DocsPlugins.QualifierDoc(
                name: "pick-random",
                inputTypes: ["List"],
                description: "Pick one element",
                acceptsParameters: false
            )
        ]

        let html = DocsPlugins.generateHTML(metadata: metadata, info: info)
        #expect(html.contains("<h1>plugin-collection (<code>Collections</code>)</h1>"))
        #expect(html.contains("<code>collections.pick-random</code>"))
        #expect(html.contains("Collection helpers"))
        // Escaping must not mangle ordinary text.
        #expect(!html.contains("&amp;lt;"))
    }
}
