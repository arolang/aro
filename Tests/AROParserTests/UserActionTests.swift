// ============================================================
// UserActionTests.swift
// AROParser - Tests for user-defined actions (ARO-0081)
// ============================================================

import Testing
import Foundation
@testable import AROParser

@Suite("User-Defined Actions (ARO-0081)")
struct UserActionTests {

    // MARK: - Parser

    @Suite("Parser")
    struct ParserTests {

        @Test("Plain Action header without takes clause")
        func plainAction() throws {
            let source = """
            (DoubleValue: Action) {
                Return an <OK: status> with <result>.
            }
            """
            let program = try Parser.parse(source)
            #expect(program.featureSets.count == 1)
            let fs = program.featureSets[0]
            #expect(fs.businessActivity == "Action")
            #expect(fs.isUserAction == true)
            #expect(fs.userActionTakesField == nil)
            #expect(fs.userActionTakesType == nil)
        }

        @Test("Action header with takes <field>")
        func actionWithTakesField() throws {
            let source = """
            (DoubleValue: Action takes <number>) {
                Return an <OK: status> with <result>.
            }
            """
            let program = try Parser.parse(source)
            let fs = program.featureSets[0]
            #expect(fs.businessActivity == "Action")
            #expect(fs.isUserAction == true)
            #expect(fs.userActionTakesField == "number")
            #expect(fs.userActionTakesType == nil)
        }

        @Test("Action header with takes <field: Type>")
        func actionWithTakesFieldAndType() throws {
            let source = """
            (DoubleValue: Action takes <number: Integer>) {
                Return an <OK: status> with <result>.
            }
            """
            let program = try Parser.parse(source)
            let fs = program.featureSets[0]
            #expect(fs.userActionTakesField == "number")
            #expect(fs.userActionTakesType == "Integer")
        }

        @Test("Non-Action feature sets are not user actions")
        func nonActionIsNotUserAction() throws {
            let source = """
            (Application-Start: Demo) {
                Return an <OK: status> for the <startup>.
            }
            """
            let program = try Parser.parse(source)
            let fs = program.featureSets[0]
            #expect(fs.isUserAction == false)
            #expect(fs.userActionTakesField == nil)
        }
    }

    // MARK: - splitUserActionHeader

    @Suite("Header Decomposition")
    struct HeaderTests {

        @Test("Plain Action passes through")
        func plainActionPassesThrough() {
            let (activity, takes, type) = Parser.splitUserActionHeader("Action")
            #expect(activity == "Action")
            #expect(takes == nil)
            #expect(type == nil)
        }

        @Test("Action takes<number> splits cleanly")
        func actionWithField() {
            let (activity, takes, type) = Parser.splitUserActionHeader("Action takes<number>")
            #expect(activity == "Action")
            #expect(takes == "number")
            #expect(type == nil)
        }

        @Test("Action takes<number:Integer> recovers type")
        func actionWithFieldAndType() {
            let (activity, takes, type) = Parser.splitUserActionHeader("Action takes<number:Integer>")
            #expect(activity == "Action")
            #expect(takes == "number")
            #expect(type == "Integer")
        }

        @Test("Unrelated activity is unchanged")
        func unrelatedUnchanged() {
            let (activity, takes, type) = Parser.splitUserActionHeader("UserCreated Handler")
            #expect(activity == "UserCreated Handler")
            #expect(takes == nil)
            #expect(type == nil)
        }
    }

    // MARK: - UserActionRegistry

    @Suite("Registry")
    struct RegistryTests {

        @Test("actionName(fromCallVerb:) extracts the bare name")
        func extractBareName() {
            #expect(UserActionRegistry.actionName(fromCallVerb: "Application.DoubleValue") == "DoubleValue")
            #expect(UserActionRegistry.actionName(fromCallVerb: "Greeting.Greet") == nil)
            #expect(UserActionRegistry.actionName(fromCallVerb: "Compute") == nil)
            #expect(UserActionRegistry.actionName(fromCallVerb: "Application.") == nil)
        }

        @Test("Registry built from program lists user actions")
        func registryListsActions() {
            let source = """
            (DoubleValue: Action takes <number>) {
                Return an <OK: status> with <result>.
            }
            (Halve: Action takes <number>) {
                Return an <OK: status> with <result>.
            }
            (Application-Start: Demo) {
                Return an <OK: status> for the <startup>.
            }
            """
            let program = try? Parser.parse(source)
            let analyzer = SemanticAnalyzer()
            let analyzed = analyzer.analyze(program!)
            #expect(analyzed.userActions.allNames == ["DoubleValue", "Halve"])
            #expect(analyzed.userActions.info(for: "DoubleValue")?.takesField == "number")
        }
    }

    // MARK: - Diagnostics

    @Suite("Diagnostics")
    struct DiagnosticTests {

        @Test("Duplicate action names emit an error")
        func duplicateAction() {
            let diagnostics = DiagnosticCollector()
            let source = """
            (DoubleValue: Action takes <number>) {
                Return an <OK: status> with <result>.
            }
            (DoubleValue: Action) {
                Return an <OK: status> with <result>.
            }
            """
            let program = try? Parser.parse(source, diagnostics: diagnostics)
            _ = SemanticAnalyzer(diagnostics: diagnostics).analyze(program!)
            let messages = diagnostics.diagnostics.map { $0.message }
            #expect(messages.contains { $0.contains("Duplicate user-defined action") })
        }

        @Test("Unknown Application.<Name> calls emit an error")
        func unknownApplicationCall() {
            let diagnostics = DiagnosticCollector()
            let source = """
            (Application-Start: Demo) {
                Application.NoSuch the <x> with { a: 1 }.
                Return an <OK: status> for the <startup>.
            }
            """
            let program = try? Parser.parse(source, diagnostics: diagnostics)
            _ = SemanticAnalyzer(diagnostics: diagnostics).analyze(program!)
            let messages = diagnostics.diagnostics.map { $0.message }
            #expect(messages.contains { $0.contains("Unknown user-defined action 'Application.NoSuch'") })
        }

        @Test("Sugar form against action without takes is rejected")
        func sugarWithoutTakes() {
            let diagnostics = DiagnosticCollector()
            let source = """
            (Plain: Action) {
                Return an <OK: status> with <result>.
            }
            (Application-Start: Demo) {
                Application.Plain the <x> from 5.
                Return an <OK: status> for the <startup>.
            }
            """
            let program = try? Parser.parse(source, diagnostics: diagnostics)
            _ = SemanticAnalyzer(diagnostics: diagnostics).analyze(program!)
            let messages = diagnostics.diagnostics.map { $0.message }
            #expect(messages.contains { $0.contains("Cannot call 'Application.Plain' with `from <value>`") })
        }

        @Test("Framework variables inside Action body are rejected")
        func frameworkVarRejected() {
            let diagnostics = DiagnosticCollector()
            let source = """
            (BadAction: Action) {
                Extract the <body> from the <request: body>.
                Return an <OK: status> with <body>.
            }
            """
            let program = try? Parser.parse(source, diagnostics: diagnostics)
            _ = SemanticAnalyzer(diagnostics: diagnostics).analyze(program!)
            let messages = diagnostics.diagnostics.map { $0.message }
            #expect(messages.contains { $0.contains("Framework variable '<request>'") })
        }

        @Test("Framework variables outside Action body are allowed")
        func frameworkVarAllowedElsewhere() {
            let diagnostics = DiagnosticCollector()
            let source = """
            (createUser: User API) {
                Extract the <body> from the <request: body>.
                Return an <OK: status> with <body>.
            }
            """
            let program = try? Parser.parse(source, diagnostics: diagnostics)
            _ = SemanticAnalyzer(diagnostics: diagnostics).analyze(program!)
            let messages = diagnostics.diagnostics.map { $0.message }
            #expect(messages.allSatisfy { !$0.contains("Framework variable") })
        }
    }
}
