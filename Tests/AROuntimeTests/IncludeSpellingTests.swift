// ============================================================
// IncludeSpellingTests.swift
// ARO Runtime - the Include spelling that runs (GitLab #563)
// ============================================================
//
// ARO-0050 §10 specified two forms, and neither worked:
//
//     {{ Include the <template: header.tpl>. }}
//     {{ Include the <template: user-card.tpl> with { user: <currentUser> }. }}
//
// The first has no preposition clause, which the Action-Result-Object grammar
// requires of every statement, so it is a parse error. The second parses and
// renders **nothing** — with `with` as the primary preposition the object is an
// expression, and `FeatureSetExecutor`'s `!needsExecution` fast path binds that
// expression's value to the result and never dispatches the action. So the
// include silently did not happen.
//
// The capability was complete all along through `from`, which is what the
// proposal now specifies. `IncludeAction` declaring only `from` is what gets
// the bad spelling reported at check time instead of rendering empty.

import Foundation
import Testing
@testable import ARORuntime
import AROParser

@Suite("Include spellings (GitLab #563)")
struct IncludeSpellingTests {

    /// Render `page` with `partials` available beside it.
    private func render(_ page: String, partials: [String: String]) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-563-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, body) in partials {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(body.utf8).write(to: url)
        }
        let pageURL = dir.appendingPathComponent("page.tpl")
        try Data(page.utf8).write(to: pageURL)

        let parsed = try TemplateParser().parse(page, path: "page.tpl")
        let eventBus = EventBus()
        let context = RuntimeContext(featureSetName: "Test", eventBus: eventBus)
        let service = AROTemplateService(templatesDirectory: dir.path)
        context.register(service as any TemplateService)

        let executor = TemplateExecutor(actionRegistry: .shared, eventBus: eventBus)
        // A partial is rendered through the service, which needs the executor —
        // exactly as `Application` wires it at startup.
        service.setExecutor(executor)
        return try await executor.render(template: parsed, context: context, templateService: service)
    }

    // MARK: - The spelling that runs

    @Test("`Include the <part> from the <template: …>.` renders inline")
    func fromFormRenders() async throws {
        let output = try await render(
            "A: {{ Include the <part> from the <template: partials/header.tpl>. }}",
            partials: ["partials/header.tpl": "[HEADER]"]
        )
        #expect(output.contains("[HEADER]"))
    }

    @Test("A trailing `with` clause passes overrides into the partial")
    func trailingWithPassesOverrides() async throws {
        // `with` after `from` is a trailing clause, not the primary
        // preposition, so the action does dispatch and the overrides land.
        let output = try await render(
            #"C: {{ Include the <c> from the <template: partials/card.tpl> with { label: "Go" }. }}"#,
            partials: ["partials/card.tpl": "[CARD label={{ <label> }}]"]
        )
        #expect(output.contains("[CARD label=Go]"))
    }

    @Test("A nested include reaches a partial of a partial")
    func nestedInclude() async throws {
        let output = try await render(
            "{{ Include the <outer> from the <template: partials/outer.tpl>. }}",
            partials: [
                "partials/outer.tpl": "<{{ Include the <inner> from the <template: partials/inner.tpl>. }}>",
                "partials/inner.tpl": "IN",
            ]
        )
        #expect(output.contains("<IN>"))
    }

    // MARK: - The declaration that reports the bad spelling

    @Test("Include declares only `from`, so `with` is reported at check time")
    func withIsNotDeclared() {
        #expect(IncludeAction.validPrepositions == [.from])
        // The catalog the parser checks against has to agree, or `aro check`
        // stays silent about a spelling the runtime cannot honour.
        for verb in IncludeAction.verbs {
            #expect(PrepositionCatalog.prepositions(forVerb: verb) == [.from],
                    "\(verb) disagrees with IncludeAction")
        }
    }

    @Test("Every Include synonym takes the same preposition")
    func synonymsAgree() {
        #expect(IncludeAction.verbs == ["include", "embed", "insert"])
    }
}
