// ============================================================
// PositionalHeaderTests.swift
// ARO Parser — `Application-Start … takes <a> <b>`
// ARO-0047 §Positional Arguments, GitLab #857
// ============================================================
//
// ARO-0081 gave `Action takes <field>` for user-defined actions. The same
// clause on `Application-Start` declares the positional command-line arguments
// an application reads — one header form, two meanings, because the
// declaration is the same thing in both: the inputs this unit is called with.

import Foundation
import Testing
@testable import AROParser

@Suite("Positional argument headers (#857)")
struct PositionalHeaderTests {

    private func parse(_ source: String) throws -> Program {
        let tokens = try Lexer(source: source).tokenize()
        return try Parser(tokens: tokens).parse()
    }

    private func entry(_ source: String) throws -> FeatureSet? {
        try parse(source).featureSets.first { $0.name == "Application-Start" }
    }

    @Test("one positional is declared")
    func singlePositional() throws {
        let fs = try entry("""
        (Application-Start: Crawler takes <url>) {
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(fs?.positionalParameters == ["url"])
        #expect(fs?.businessActivity == "Crawler")
    }

    @Test("several positionals keep their order")
    func severalPositionals() throws {
        let fs = try entry("""
        (Application-Start: Crawler takes <url> <depth>) {
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(fs?.positionalParameters == ["url", "depth"])
    }

    @Test("commas between positionals are optional")
    func commasAreOptional() throws {
        let juxtaposed = try entry("""
        (Application-Start: Crawler takes <url> <depth>) {
            Return an <OK: status> for the <startup>.
        }
        """)
        let withCommas = try entry("""
        (Application-Start: Crawler takes <url>, <depth>) {
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(juxtaposed?.positionalParameters == withCommas?.positionalParameters)
        #expect(withCommas?.positionalParameters == ["url", "depth"])
    }

    @Test("a header with no takes clause declares nothing")
    func noClauseNoPositionals() throws {
        let fs = try entry("""
        (Application-Start: Crawler) {
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(fs?.positionalParameters.isEmpty == true)
        #expect(fs?.businessActivity == "Crawler")
    }

    @Test("a multi-word business activity survives the clause")
    func multiWordActivity() throws {
        let fs = try entry("""
        (Application-Start: Web Crawler takes <url>) {
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(fs?.businessActivity == "Web Crawler")
        #expect(fs?.positionalParameters == ["url"])
    }

    // MARK: - ARO-0081 is unaffected

    @Test("an Action still declares its single takes field")
    func userActionUnchanged() throws {
        let program = try parse("""
        (DoubleValue: Action takes <number>) {
            Return an <OK: status> with <number>.
        }
        """)
        let action = program.featureSets.first
        #expect(action?.businessActivity == "Action")
        #expect(action?.userActionTakesField == "number")
        #expect(action?.positionalParameters.isEmpty == true)
    }

    @Test("an Action's type annotation still parses")
    func userActionTypeAnnotation() throws {
        let program = try parse("""
        (DoubleValue: Action takes <number: Integer>) {
            Return an <OK: status> with <number>.
        }
        """)
        #expect(program.featureSets.first?.userActionTakesField == "number")
        #expect(program.featureSets.first?.userActionTakesType == "Integer")
    }

    // MARK: - The splitter

    @Test("splitTakesHeader recovers the structured form")
    func splitterRoundTrip() {
        let (activity, fields) = Parser.splitTakesHeader("Crawler takes<url>,<depth:Integer>")
        #expect(activity == "Crawler")
        #expect(fields == [Parser.TakesField(name: "url", type: nil),
                           Parser.TakesField(name: "depth", type: "Integer")])
    }

    @Test("a header with no clause passes through untouched")
    func splitterPassesThrough() {
        let (activity, fields) = Parser.splitTakesHeader("User API")
        #expect(activity == "User API")
        #expect(fields.isEmpty)
    }

    @Test("a state-guard suffix is not a takes clause")
    func stateGuardIsNotTakes() {
        // `StateObserver<draft_to_placed>` uses the same angle-bracket suffix
        // machinery and must keep meaning what it meant.
        let (activity, fields) = Parser.splitTakesHeader("StateObserver<draft_to_placed>")
        #expect(activity == "StateObserver<draft_to_placed>")
        #expect(fields.isEmpty)
    }
}
