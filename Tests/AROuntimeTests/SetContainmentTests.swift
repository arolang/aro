// ============================================================
// SetContainmentTests.swift
// ARO Runtime — subset of, and symmetric difference
// ARO-0042 §3.6 / §3.7, GitLab #864
// ============================================================
//
// ARO-0042 gave union, intersect and difference. `subset of` was written as an
// intersect plus a length comparison — which is not quite the same question,
// because `intersect` is multiset — and symmetric difference as two
// differences and a union.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Set containment and symmetric difference (#864)")
struct SetContainmentTests {

    // MARK: - subset of

    private func isSubset(_ a: any Sendable, of b: any Sendable) async throws -> Bool {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("a", value: a)
        context.bind("b", value: b)
        let expression = BinaryExpression(
            left: VariableRefExpression(noun: QualifiedNoun(base: "a", specifiers: [], span: span), span: span),
            op: .subset,
            right: VariableRefExpression(noun: QualifiedNoun(base: "b", specifiers: [], span: span), span: span),
            span: span)
        let value = try await ExpressionEvaluator().evaluate(expression, context: context)
        return value as? Bool ?? false
    }

    @Test("every element present is a subset")
    func listSubset() async throws {
        #expect(try await isSubset(["read", "write"], of: ["read", "write", "admin"]))
    }

    @Test("a missing element is not")
    func listNotSubset() async throws {
        #expect(try await isSubset(["read", "delete"], of: ["read", "write"]) == false)
    }

    @Test("the empty set is a subset of everything, itself included")
    func emptyIsAlwaysSubset() async throws {
        // The mathematical convention and the useful one: a route that
        // requires no roles admits every caller.
        #expect(try await isSubset([any Sendable](), of: ["read"]))
        #expect(try await isSubset([any Sendable](), of: [any Sendable]()))
    }

    @Test("a set is a subset of itself")
    func reflexive() async throws {
        #expect(try await isSubset(["a", "b"], of: ["a", "b"]))
    }

    @Test("containment is set semantics, not multiset")
    func duplicatesDoNotCount() async throws {
        // This is what the intersect-plus-length workaround got wrong: the
        // question is about membership, and a duplicate does not make a new
        // member. It is the one place in ARO-0042 that is not multiset.
        #expect(try await isSubset([1, 1, 1], of: [1]))
    }

    @Test("a bare scalar counts as a one-element set")
    func scalarSubset() async throws {
        #expect(try await isSubset("admin", of: ["admin", "user"]))
        #expect(try await isSubset("owner", of: ["admin", "user"]) == false)
    }

    @Test("strings compare by character")
    func stringSubset() async throws {
        #expect(try await isSubset("ace", of: "abcde"))
        #expect(try await isSubset("axe", of: "abcde") == false)
    }

    @Test("objects need the key and an equal value")
    func objectSubset() async throws {
        let small: [String: any Sendable] = ["role": "admin"]
        let big: [String: any Sendable] = ["role": "admin", "tier": "gold"]
        let different: [String: any Sendable] = ["role": "user", "tier": "gold"]
        #expect(try await isSubset(small, of: big))
        #expect(try await isSubset(small, of: different) == false)
        #expect(try await isSubset(big, of: small) == false)
    }

    @Test("a list is a subset of an object when its elements are keys")
    func listOfObjectKeys() async throws {
        let record: [String: any Sendable] = ["id": 1, "name": "a", "email": "b"]
        #expect(try await isSubset(["id", "name"], of: record))
        #expect(try await isSubset(["id", "phone"], of: record) == false)
    }

    @Test("containment is not symmetric")
    func notSymmetric() async throws {
        #expect(try await isSubset(["a"], of: ["a", "b"]))
        #expect(try await isSubset(["a", "b"], of: ["a"]) == false)
    }

    // MARK: - symmetric-difference

    private func symmetricDifference(_ a: any Sendable, _ b: any Sendable) async throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: a)
        context.bind("_with_", value: b)
        return try await ComputeAction().execute(
            result: ResultDescriptor(base: "out", specifiers: ["symmetric-difference"], span: span),
            object: ObjectDescriptor(preposition: .from, base: "input", specifiers: [], span: span),
            context: context)
    }

    @Test("what is in exactly one of the two")
    func listSymmetricDifference() async throws {
        let value = try await symmetricDifference(["read", "write", "admin"],
                                                  ["read", "write", "billing"])
        let elements = (value as? [any Sendable])?.map { "\($0)" } ?? []
        #expect(Set(elements) == ["admin", "billing"])
    }

    @Test("with itself, nothing")
    func symmetricDifferenceOfSelf() async throws {
        // The cheapest "did anything change" a program can ask.
        let value = try await symmetricDifference(["a", "b"], ["a", "b"])
        #expect((value as? [any Sendable])?.isEmpty == true)
    }

    @Test("with an empty set, everything")
    func symmetricDifferenceWithEmpty() async throws {
        let value = try await symmetricDifference(["a", "b"], [any Sendable]())
        #expect((value as? [any Sendable])?.count == 2)
    }

    @Test("it is symmetric")
    func orderDoesNotMatter() async throws {
        let forwards = try await symmetricDifference(["a", "b"], ["b", "c"])
        let backwards = try await symmetricDifference(["b", "c"], ["a", "b"])
        let f = Set((forwards as? [any Sendable])?.map { "\($0)" } ?? [])
        let b = Set((backwards as? [any Sendable])?.map { "\($0)" } ?? [])
        #expect(f == b)
    }

    @Test("strings differ character-wise")
    func stringSymmetricDifference() async throws {
        let value = try await symmetricDifference("abc", "bcd")
        let text = value as? String ?? ""
        #expect(text.contains("a"))
        #expect(text.contains("d"))
        #expect(!text.contains("b"))
    }

    @Test("objects keep the keys that differ")
    func objectSymmetricDifference() async throws {
        let before: [String: any Sendable] = ["role": "admin", "tier": "gold"]
        let after: [String: any Sendable] = ["role": "admin", "tier": "silver"]
        let value = try await symmetricDifference(before, after)
        let record = try #require(value as? [String: any Sendable])
        #expect(record["tier"] != nil)
        #expect(record["role"] == nil)
    }

    @Test("a missing `with` clause is an error naming it")
    func missingOperand() async {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: ["a"])
        await #expect(throws: (any Error).self) {
            _ = try await ComputeAction().execute(
                result: ResultDescriptor(base: "out", specifiers: ["symmetric-difference"], span: span),
                object: ObjectDescriptor(preposition: .from, base: "input", specifiers: [], span: span),
                context: context)
        }
    }

    // MARK: - The catalogs agree

    @Test("the parser's catalog knows symmetric-difference")
    func catalogAgrees() {
        // `aro check` never loads the runtime, so a green check has to mean
        // the qualifier exists.
        #expect(ComputeQualifierCatalog.builtIns.contains("symmetric-difference"))
    }

    @Test("subset is not a Compute qualifier, and should not be")
    func subsetIsNotAQualifier() {
        // It is a predicate: it answers a question rather than producing a
        // collection, so it lives with the condition operators.
        #expect(ComputeQualifierCatalog.builtIns.contains("subset") == false)
    }
}
