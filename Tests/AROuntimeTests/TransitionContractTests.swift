// ============================================================
// TransitionContractTests.swift
// The declared state set behind Accept (GitLab #507)
// ============================================================
//
// Before this, `Accept the <transition: draft_to_teleported> on
// <order: status>.` passed `aro check`, built, ran, and left the order
// in a state called "teleported" that no contract had ever heard of —
// the only check was that the entity was already in the from-state.
// The contract's `enum` is now the authority on which states exist.

import Testing
import Foundation
@testable import ARORuntime
@testable import AROParser

@Suite("Transition contract (GitLab #507)")
struct TransitionContractTests {

    // MARK: - Fixtures

    /// The idiomatic spelling: the state property `$ref`s a named string
    /// enum, exactly as `Examples/OrderService/openapi.yaml` does.
    private static let orderContract = """
    openapi: 3.0.3
    info:
      title: Order API
      version: 1.0.0
    paths: {}
    components:
      schemas:
        OrderStatus:
          type: string
          enum:
            - draft
            - placed
            - paid
            - shipped
        Order:
          type: object
          properties:
            id:
              type: string
            status:
              $ref: '#/components/schemas/OrderStatus'
    """

    private func spec(_ yaml: String = orderContract) throws -> OpenAPISpec {
        try OpenAPILoader.parse(data: Data(yaml.utf8), filename: "openapi.yaml")
    }

    private func featureSets(_ body: String) -> [FeatureSet] {
        Compiler().compile("""
        (Application-Start: Test) {
        \(body)
            Return an <OK: status> for the <startup>.
        }
        """).program.featureSets
    }

    // MARK: - Reading the contract

    @Test("A state enum reached through a $ref is a declared state set")
    func declaredStatesFollowRefs() throws {
        let declared = TransitionContractValidator.declaredStates(in: try spec())

        #expect(declared.count == 1)
        let states = try #require(declared.first)
        #expect(states.schemaName == "Order")
        #expect(states.propertyName == "status")
        #expect(states.states == ["draft", "placed", "paid", "shipped"])
        #expect(states.contractPath == "components.schemas.Order.status")
    }

    @Test("A non-string enum is not a state set")
    func numericEnumIsNotAStateSet() throws {
        let contract = """
        openapi: 3.0.3
        info: { title: T, version: 1.0.0 }
        paths: {}
        components:
          schemas:
            Order:
              type: object
              properties:
                priority:
                  type: integer
                  enum: [1, 2, 3]
        """
        #expect(TransitionContractValidator.declaredStates(in: try spec(contract)).isEmpty)
    }

    // MARK: - Declared transitions pass

    @Test("A transition between two declared states passes the check")
    func declaredTransitionPasses() throws {
        let diagnostics = TransitionContractValidator.validate(
            featureSets("""
                Create the <order> with { id: "1", status: "draft" }.
                Accept the <transition: draft_to_placed> on <order: status>.
            """),
            against: try spec()
        )
        #expect(diagnostics.isEmpty)
    }

    @Test("Every transition in Examples/OrderService is declared")
    func orderServiceExampleIsClean() throws {
        // The example ships the state machine this feature is modelled on;
        // if it ever stops checking clean the diagnostic is wrong, not it.
        let body = """
            Retrieve the <order> from the <order-repository> where <id> is "1".
            Accept the <transition: draft_to_placed> on <order: status>.
            Accept the <transition: placed_to_paid> on <order: status>.
            Accept the <transition: paid_to_shipped> on <order: status>.
        """
        #expect(TransitionContractValidator.validate(
            featureSets(body),
            against: try spec()
        ).isEmpty)
    }

    // MARK: - Undeclared states fail

    @Test("An undeclared state is an error naming state, transition, schema and the declared set")
    func undeclaredStateIsAnError() throws {
        let diagnostics = TransitionContractValidator.validate(
            featureSets("""
                Create the <order> with { id: "1", status: "draft" }.
                Accept the <transition: draft_to_teleported> on <order: status>.
            """),
            against: try spec()
        )

        #expect(diagnostics.count == 1)
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.severity == .error)
        // The offending state, and the transition it came out of.
        #expect(diagnostic.message.contains("'teleported'"))
        #expect(diagnostic.message.contains("draft_to_teleported"))
        #expect(diagnostic.message.contains("<order: status>"))
        // The schema it was checked against, and what that schema declares.
        #expect(diagnostic.hints.contains { $0.contains("components.schemas.Order.status") })
        #expect(diagnostic.hints.contains { $0.contains("draft, placed, paid, shipped") })
        // And where the statement is.
        #expect(diagnostic.location != nil)
    }

    @Test("A typo gets a closest-match hint")
    func typoGetsClosestMatchHint() throws {
        let diagnostics = TransitionContractValidator.validate(
            featureSets("    Accept the <transition: paid_to_shiped> on <order: status>."),
            against: try spec()
        )
        let diagnostic = try #require(diagnostics.first)
        #expect(diagnostic.hints.contains { $0.contains("Closest declared state: shipped") })
    }

    @Test("Both halves are reported when both are undeclared")
    func bothHalvesReported() throws {
        let diagnostics = TransitionContractValidator.validate(
            featureSets("    Accept the <transition: nowhere_to_elsewhere> on <order: status>."),
            against: try spec()
        )
        #expect(diagnostics.count == 2)
        #expect(diagnostics.contains { $0.message.contains("'nowhere'") })
        #expect(diagnostics.contains { $0.message.contains("'elsewhere'") })
    }

    @Test("An Accept nested in a for-each is checked too")
    func nestedAcceptIsChecked() throws {
        let sets = Compiler().compile("""
        (Application-Start: Test) {
            Retrieve the <orders> from the <order-repository>.
            for each <order> in <orders> {
                Accept the <transition: draft_to_teleported> on <order: status>.
            }
            Return an <OK: status> for the <startup>.
        }
        """).program.featureSets

        #expect(TransitionContractValidator.validate(sets, against: try spec()).count == 1)
    }

    // MARK: - Resolving the entity to a schema

    @Test("Entity names reach their schema through case, plural and compound spellings")
    func entityResolution() throws {
        let declared = TransitionContractValidator.declaredStates(in: try spec())
        for entity in ["order", "Order", "orders", "picked-order", "espresso_order"] {
            let resolved = TransitionContractValidator.resolve(
                entity: entity, field: "status", in: declared
            )
            #expect(resolved?.schemaName == "Order", "entity '\(entity)' should reach Order")
        }
    }

    @Test("An unrelated entity still resolves when the contract declares exactly one such state set")
    func unambiguousFallback() throws {
        // `doc2` matches no schema name, but the contract has exactly one
        // `status` enum — that enum *is* the state machine.
        let declared = TransitionContractValidator.declaredStates(in: try spec())
        #expect(TransitionContractValidator.resolve(
            entity: "doc2", field: "status", in: declared
        )?.schemaName == "Order")
    }

    @Test("Two competing state sets and no name match means no enforcement")
    func ambiguousMeansSilent() throws {
        let contract = """
        openapi: 3.0.3
        info: { title: T, version: 1.0.0 }
        paths: {}
        components:
          schemas:
            Order:
              type: object
              properties:
                status:
                  type: string
                  enum: [draft, placed]
            Ticket:
              type: object
              properties:
                status:
                  type: string
                  enum: [open, closed]
        """
        let sets = featureSets("    Accept the <transition: mystery_to_unknown> on <thing: status>.")
        #expect(TransitionContractValidator.validate(sets, against: try spec(contract)).isEmpty)
        // …but a named entity is still held to its own schema.
        let named = featureSets("    Accept the <transition: open_to_placed> on <ticket: status>.")
        let diagnostics = TransitionContractValidator.validate(named, against: try spec(contract))
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains("'placed'") == true)
    }

    @Test("A field the contract says nothing about is not enforced")
    func unknownFieldIsSilent() throws {
        let sets = featureSets("    Accept the <transition: cold_to_hot> on <order: phase>.")
        #expect(TransitionContractValidator.validate(sets, against: try spec()).isEmpty)
    }

    // MARK: - No contract, no enforcement

    @Test("A directory without a contract is not enforced")
    func contractLessDirectoryIsSilent() throws {
        // The path `aro build` takes: hand it the application root and let
        // it look for openapi.yaml itself. `Examples/StateMachine` used to
        // be exactly this shape — states invented in code, nothing to check
        // them against — and such a project must keep building.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-507-no-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sets = featureSets("    Accept the <transition: draft_to_teleported> on <order: status>.")
        #expect(TransitionContractValidator.validate(sets, inDirectory: directory).isEmpty)
    }

    @Test("A contract on disk is found and enforced")
    func contractOnDiskIsEnforced() throws {
        // Same call `aro build` makes, against a real openapi.yaml.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-507-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.orderContract.write(
            to: directory.appendingPathComponent("openapi.yaml"),
            atomically: true,
            encoding: .utf8
        )

        let sets = featureSets("    Accept the <transition: draft_to_teleported> on <order: status>.")
        let diagnostics = TransitionContractValidator.validate(sets, inDirectory: directory)
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.hints.contains { $0.contains("openapi.yaml") } == true)

        // And the declared spelling builds.
        let good = featureSets("    Accept the <transition: draft_to_placed> on <order: status>.")
        #expect(TransitionContractValidator.validate(good, inDirectory: directory).isEmpty)
    }

    @Test("A contract with no schemas at all is not enforced")
    func schemaLessContractIsSilent() throws {
        let contract = """
        openapi: 3.0.3
        info: { title: T, version: 1.0.0 }
        paths: {}
        """
        let sets = featureSets("    Accept the <transition: draft_to_teleported> on <order: status>.")
        #expect(TransitionContractValidator.validate(sets, against: try spec(contract)).isEmpty)
    }
}

@Suite("Transition names")
struct TransitionNameTests {

    @Test("The qualifier carries the transition")
    func qualifierSpelling() throws {
        let name = try #require(TransitionName.parse(base: "transition", specifiers: ["draft_to_placed"]))
        #expect(name.from == "draft")
        #expect(name.to == "placed")
        #expect(name.raw == "draft_to_placed")
    }

    @Test("The base carries the transition")
    func baseSpelling() throws {
        let name = try #require(TransitionName.parse(base: "draft_to_placed", specifiers: ["transition"]))
        #expect(name.from == "draft")
        #expect(name.to == "placed")
    }

    @Test("Anything without two states parses to nothing")
    func nonTransitions() {
        #expect(TransitionName.parse(base: "transition", specifiers: []) == nil)
        #expect(TransitionName.parse(base: "result", specifiers: ["length"]) == nil)
        #expect(TransitionName.parse(base: "_to_placed", specifiers: []) == nil)
        #expect(TransitionName.parse(base: "draft_to_", specifiers: []) == nil)
        #expect(TransitionName.parse(base: "a_to_b_to_c", specifiers: []) == nil)
    }
}
