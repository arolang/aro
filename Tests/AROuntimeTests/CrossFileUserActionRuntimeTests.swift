// ============================================================
// CrossFileUserActionRuntimeTests.swift
// ARO Runtime - running a multi-file application whose actions
// live in another file than their callers (GitLab #587)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Cross-file user-defined actions at runtime (GitLab #587)", .serialized)
struct CrossFileUserActionRuntimeTests {

    /// Build and run a multi-file application through the same convenience
    /// initializer `aro run` reaches, then clear the verbs it registered so the
    /// next suite does not inherit them (`ActionRegistry.shared` is
    /// process-wide).
    private func run(
        files: [(String, String)],
        actionVerbs: [String]
    ) async throws -> Response {
        defer { ActionRegistry.shared.unregisterDynamic(verbs: actionVerbs) }
        let app = try Application(
            sources: files,
            config: ApplicationConfig(verbose: false, workingDirectory: ".")
        )
        return try await app.run()
    }

    @Test("The issue's repro runs: main.aro calls Doubled, declared in other.aro")
    func crossFileCallRuns() async throws {
        let main = """
        (Application-Start: X) {
            Application.Doubled the <r> from 21.
            Extract the <v> from the <r: value>.
            Return an <OK: status> with { value: <v> }.
        }
        """
        let other = """
        (Doubled: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Compute the <out> from <n> * 2.
            Return an <OK: status> with { value: <out> }.
        }
        """
        let response = try await run(
            files: [("main.aro", main), ("other.aro", other)],
            actionVerbs: ["Application.Doubled"]
        )
        #expect(response.status == "OK")
        #expect(ResponseFormatter.format(response, for: .machine).contains("42"))
    }

    @Test("Mutual recursion across two files runs to its base case")
    func mutualRecursionAcrossFilesRuns() async throws {
        let main = """
        (Application-Start: X) {
            Application.IsEven the <r> from 10.
            Extract the <v> from the <r: answer>.
            Return an <OK: status> with { answer: <v> }.
        }

        (IsEven: Action takes <n>) {
            Extract the <n> from the <input: n>.
            Return an <OK: status> with { answer: "yes" } when <n> = 0.
            Compute the <next> from <n> - 1.
            Application.IsOdd the <sub> from <next>.
            Extract the <a> from the <sub: answer>.
            Return an <OK: status> with { answer: <a> }.
        }
        """
        let other = """
        (IsOdd: Action takes <n>) {
            Extract the <n> from the <input: n>.
            Return an <OK: status> with { answer: "no" } when <n> = 0.
            Compute the <next> from <n> - 1.
            Application.IsEven the <sub> from <next>.
            Extract the <a> from the <sub: answer>.
            Return an <OK: status> with { answer: <a> }.
        }
        """
        let response = try await run(
            files: [("main.aro", main), ("other.aro", other)],
            actionVerbs: ["Application.IsEven", "Application.IsOdd"]
        )
        #expect(response.status == "OK")
        #expect(ResponseFormatter.format(response, for: .machine).contains("yes"))
    }

    @Test("An action declared nowhere in the application still fails to compile")
    func missingActionStillFailsToCompile() async throws {
        let main = """
        (Application-Start: X) {
            Application.Missing the <r> with { a: 1 }.
            Return an <OK: status> for the <x>.
        }
        """
        let other = """
        (Doubled: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Return an <OK: status> with { value: <n> }.
        }
        """
        #expect(throws: (any Error).self) {
            _ = try Application(
                sources: [("main.aro", main), ("other.aro", other)],
                config: ApplicationConfig(verbose: false, workingDirectory: ".")
            )
        }
    }
}
