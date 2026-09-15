// ============================================================
// TerminalTemplateFilterTests.swift
// ARO Runtime - styled literals and the length filter (GitLab #568)
// ============================================================
//
// ARO-0083 §6 and every terminal example write a styled heading as a literal:
//
//     {{ "=== Task Manager ===" | bold | color: "cyan" }}
//     Total: {{ <tasks> | length }} tasks
//
// Neither worked. Segment classification required a `<` prefix, so a literal
// fell through to statement parsing and died on "Expected action verb, but got
// string(…)". And `length` was not in the filter table — which held only the
// styling filters — and an unknown filter was skipped in silence, so
// `{{ <tasks> | length }}` printed the whole collection with no diagnostic.

import Foundation
import Testing
@testable import ARORuntime

@Suite("Terminal template filters (GitLab #568)")
struct TerminalTemplateFilterTests {

    private func render(
        _ body: String,
        filename: String = "screen.screen",
        bindings: [String: any Sendable]
    ) async throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aro-568-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appendingPathComponent(filename)
        try Data(body.utf8).write(to: path)
        let parsed = try TemplateParser().parse(body, path: filename)

        let eventBus = EventBus()
        let context = RuntimeContext(featureSetName: "Test", eventBus: eventBus)
        for (name, value) in bindings { context.bind(name, value: value) }

        let service = AROTemplateService(templatesDirectory: dir.path)
        context.register(service as any TemplateService)
        let executor = TemplateExecutor(actionRegistry: .shared, eventBus: eventBus)
        service.setExecutor(executor)
        return try await executor.render(template: parsed, context: context, templateService: service)
    }

    // MARK: - A styled string literal

    @Test("A literal with a style filter renders its text")
    func styledLiteralRenders() async throws {
        let output = try await render(
            #"{{ "=== Task Manager ===" | bold }}"#, bindings: [:])
        #expect(output.contains("=== Task Manager ==="))
    }

    @Test("A chain of filters on a literal renders, as ARO-0083 §6 writes it")
    func chainedFiltersOnLiteral() async throws {
        let output = try await render(
            #"{{ "=== Task Manager ===" | bold | color: "cyan" }}"#, bindings: [:])
        #expect(output.contains("=== Task Manager ==="))
    }

    @Test("A pipe inside the literal is not mistaken for a filter separator")
    func pipeInsideLiteral() async throws {
        let output = try await render(#"{{ "a|b" | bold }}"#, bindings: [:])
        #expect(output.contains("a|b"))
    }

    @Test("A bare literal is still not a shorthand — static text belongs outside")
    func bareLiteralIsStillRejected() async {
        // Chapter 44 §44.3's rule. Only a *filtered* literal is an expression:
        // styling is the reason to put a literal inside the braces at all.
        await #expect(throws: (any Error).self) {
            _ = try await render(#"{{ "just text" }}"#, bindings: [:])
        }
    }

    // MARK: - The length filter

    @Test("`| length` on a collection is its element count")
    func lengthOfCollection() async throws {
        let output = try await render(
            "Total: {{ <tasks> | length }} tasks",
            bindings: ["tasks": ["a", "b", "c"] as [any Sendable]]
        )
        // Printed the whole collection before — `["a", "b", "c"]` in place of
        // the count. The bracket is what tells the two apart; "a" alone does
        // not, since "tasks" contains one.
        #expect(output.contains("Total: 3 tasks"))
        #expect(!output.contains("["), "the collection itself was rendered: \(output)")
    }

    @Test("`| length` on a string is its character count")
    func lengthOfString() async throws {
        let output = try await render(
            "{{ <title> | length }}", bindings: ["title": "hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "5")
    }

    @Test("`| count` is the same filter under the other name")
    func countIsAnAlias() async throws {
        let output = try await render(
            "{{ <tasks> | count }}",
            bindings: ["tasks": ["a", "b"] as [any Sendable]]
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    @Test("`| length` on a record counts its fields")
    func lengthOfRecord() async throws {
        let output = try await render(
            "{{ <user> | length }}",
            bindings: ["user": ["id": 1, "name": "Ada"] as [String: any Sendable]]
        )
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
    }

    // MARK: - Together, as the example ships them

    @Test("The shipped task-list template's shapes all render")
    func taskListShapes() async throws {
        let output = try await render("""
        {{ "=== Task Manager ===" | bold | color: "cyan" }}
        {{ "Tasks:" | bold }}
        {{ for each <task> in <tasks> { }}
          [{{ <task: id> }}] {{ <task: title> | color: "white" }}
        {{ } }}
        Total: {{ <tasks> | length }} tasks
        """, bindings: [
            "tasks": [
                ["id": 1, "title": "Write docs"] as [String: any Sendable],
                ["id": 2, "title": "Fix bug"] as [String: any Sendable],
            ] as [any Sendable]
        ])

        #expect(output.contains("=== Task Manager ==="))
        #expect(output.contains("Tasks:"))
        #expect(output.contains("[1] Write docs"))
        #expect(output.contains("[2] Fix bug"))
        #expect(output.contains("Total: 2 tasks"))
    }

    // MARK: - The pipe finder

    @Test("The filter pipe is found outside brackets and strings alike")
    func filterPipeScanning() {
        func split(_ s: String) -> String? {
            TemplateParser.findFilterPipe(s).map { String(s[..<$0]).trimmingCharacters(in: .whitespaces) }
        }
        #expect(split("<x> | bold") == "<x>")
        #expect(split(#""a|b" | bold"#) == #""a|b""#)
        #expect(split("<x>") == nil)
        #expect(split(#""a|b""#) == nil)
    }
}
