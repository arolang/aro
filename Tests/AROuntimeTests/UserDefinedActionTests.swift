// ============================================================
// UserDefinedActionTests.swift
// ARO Runtime - End-to-end tests for user-defined actions (ARO-0081)
// ============================================================

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("User-Defined Actions Runtime (ARO-0081)")
struct UserDefinedActionTests {

    /// Compile and run a snippet, returning the analyzed program and the
    /// response from `Application-Start`. We freshly construct
    /// `ActionRegistry.shared`-bound state per test by registering and then
    /// unregistering the user actions, so tests don't see each other's verbs.
    private func runProgram(_ source: String) async throws -> (Response, AnalyzedProgram) {
        let result = Compiler().compile(source)
        #expect(result.diagnostics.allSatisfy { $0.severity != .error },
                "Compilation produced unexpected errors: \(result.diagnostics.map(\.message))")
        let runtime = Runtime()
        let response = try await runtime.run(result.analyzedProgram)
        // Clean up so the next test starts with a fresh registry.
        let host = UserDefinedActionHost(
            analyzedProgram: result.analyzedProgram,
            globalSymbols: GlobalSymbolStorage()
        )
        await host.unregister()
        return (response, result.analyzedProgram)
    }

    @Test("Sugar form passes single value to the takes field")
    func sugarFormPassesValue() async throws {
        let source = """
        (DoubleValue: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Compute the <doubled> from <n> * 2.
            Return an <OK: status> with { doubled: <doubled> }.
        }
        (Application-Start: Demo) {
            Application.DoubleValue the <d> from 5.
            Extract the <doubled> from the <d: doubled>.
            Publish as <out> <doubled>.
            Return an <OK: status> for the <startup>.
        }
        """
        let (response, _) = try await runProgram(source)
        #expect(response.status == "OK")
    }

    @Test("Object form passes the dict directly")
    func objectFormPassesDict() async throws {
        let source = """
        (Greet: Action) {
            Extract the <name> from the <input: name>.
            Return an <OK: status> with { greeting: <name> }.
        }
        (Application-Start: Demo) {
            Application.Greet the <g> with { name: "World" }.
            Extract the <greeting> from the <g: greeting>.
            Return an <OK: status> for the <startup>.
        }
        """
        let (response, _) = try await runProgram(source)
        #expect(response.status == "OK")
    }

    @Test("Composed action calls compose correctly")
    func composedActions() async throws {
        let source = """
        (DoubleValue: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Compute the <doubled> from <n> * 2.
            Return an <OK: status> with { doubled: <doubled> }.
        }
        (SumAndDouble: Action) {
            Extract the <a> from the <input: a>.
            Extract the <b> from the <input: b>.
            Compute the <sum> from <a> + <b>.
            Application.DoubleValue the <inner> from <sum>.
            Extract the <answer> from the <inner: doubled>.
            Return an <OK: status> with { value: <answer> }.
        }
        (Application-Start: Demo) {
            Application.SumAndDouble the <r> with { a: 3, b: 4 }.
            Extract the <total> from the <r: value>.
            Return an <OK: status> for the <startup>.
        }
        """
        let (response, _) = try await runProgram(source)
        #expect(response.status == "OK")
    }

    @Test("AnalyzedProgram exposes the user-action registry")
    func registryExposed() async throws {
        let source = """
        (DoubleValue: Action takes <number>) {
            Return an <OK: status> with { doubled: 0 }.
        }
        (Halve: Action) {
            Return an <OK: status> with { halved: 0 }.
        }
        (Application-Start: Demo) {
            Return an <OK: status> for the <startup>.
        }
        """
        let result = Compiler().compile(source)
        let registry = result.analyzedProgram.userActions
        #expect(registry.allNames.sorted() == ["DoubleValue", "Halve"])
        #expect(registry.info(for: "DoubleValue")?.takesField == "number")
        #expect(registry.info(forCallVerb: "Application.DoubleValue")?.name == "DoubleValue")
        #expect(registry.info(forCallVerb: "Application.Missing") == nil)
    }
}
