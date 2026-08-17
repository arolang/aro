// ============================================================
// ReverseActionTests.swift
// ARO Runtime — Reverse + the descending-sort leak (GitLab #466)
// ============================================================
//
// Two things were wrong. There was no working way to reverse a
// list at all, and the one form that *did* reverse — `Sort the
// <s: descending>` — handed back a lazy `ReversedCollection`,
// which printed as `ReversedCollection<Array<Int>>(_base: [1, 2,
// 3])`. A Swift internal was reaching user-facing output where a
// list belonged.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Reverse + descending sort (#466)")
struct ReverseActionTests {

    private func descriptors(
        resultQualifier: String? = nil,
        objectBase: String = "input",
        preposition: Preposition = .for
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        return (
            ResultDescriptor(base: "out",
                             specifiers: resultQualifier.map { [$0] } ?? [],
                             span: span),
            ObjectDescriptor(preposition: preposition, base: objectBase,
                             specifiers: [], span: span)
        )
    }

    private func reverse(_ input: any Sendable,
                         preposition: Preposition = .for) async throws -> any Sendable {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        let (result, object) = descriptors(preposition: preposition)
        return try await ReverseAction().execute(
            result: result, object: object, context: context)
    }

    private func sort(_ input: any Sendable,
                      order: String? = nil) async throws -> any Sendable {
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        let (result, object) = descriptors(resultQualifier: order)
        return try await SortAction().execute(
            result: result, object: object, context: context)
    }

    // MARK: - Reverse

    @Test("A list reverses")
    func reversesList() async throws {
        let out = try await reverse([1, 2, 3] as [any Sendable])
        #expect(out as? [Int] == [3, 2, 1])
    }

    @Test("Reversing is not sorting descending")
    func reverseIsNotDescendingSort() async throws {
        // The issue's repro reached for `Sort … descending` as a
        // substitute. They differ the moment the input isn't
        // already sorted, and conflating them would have shipped a
        // wrong answer that looks right on [1, 2, 3].
        let reversed = try await reverse([3, 1, 2] as [any Sendable])
        #expect(reversed as? [Int] == [2, 1, 3])
        let sorted = try await sort([3, 1, 2] as [any Sendable], order: "descending")
        #expect(sorted as? [Int] == [3, 2, 1])
    }

    @Test("A string reverses by character")
    func reversesString() async throws {
        #expect(try await reverse("abc") as? String == "cba")
    }

    @Test("Both documented prepositions work", arguments: [Preposition.for, .from])
    func acceptsPrepositions(preposition: Preposition) async throws {
        let out = try await reverse([1, 2] as [any Sendable], preposition: preposition)
        #expect(out as? [Int] == [2, 1])
    }

    @Test("An empty list reverses to an empty list")
    func reversesEmpty() async throws {
        let out = try await reverse([] as [any Sendable])
        #expect((out as? [any Sendable])?.isEmpty == true)
    }

    @Test("Reversing a number is an error, not a silent pass-through")
    func rejectsNonCollection() async {
        await #expect(throws: (any Error).self) {
            _ = try await reverse(5)
        }
    }

    // MARK: - Descending sort no longer leaks a Swift type

    @Test("Descending sort returns a list, not a ReversedCollection")
    func descendingSortIsAnArray() async throws {
        let out = try await sort([1, 2, 3] as [any Sendable], order: "descending")
        #expect(out as? [Int] == [3, 2, 1])
        // The regression that mattered: what the user sees.
        #expect(!String(describing: out).contains("ReversedCollection"))
    }

    @Test("Descending sort of strings is a list too")
    func descendingStringSort() async throws {
        let out = try await sort(["apple", "pear"] as [String], order: "descending")
        #expect(!String(describing: out).contains("ReversedCollection"))
        #expect(out as? [String] == ["pear", "apple"])
    }

    // MARK: - Sorting the shape ARO literals actually produce

    @Test("A list written as an ARO literal sorts")
    func sortsHeterogeneousBoxedList() async throws {
        // `[3, 1, 2]` in source arrives as `[any Sendable]`, which
        // matched none of the concrete casts — so the most common
        // shape in real code came back silently unsorted.
        let out = try await sort([3, 1, 2] as [any Sendable])
        #expect(out as? [Int] == [1, 2, 3])
    }

    @Test("A boxed string list sorts")
    func sortsBoxedStrings() async throws {
        let out = try await sort(["pear", "apple"] as [any Sendable])
        #expect(out as? [String] == ["apple", "pear"])
    }

    @Test("A mixed numeric list sorts as numbers")
    func sortsMixedNumerics() async throws {
        let out = try await sort([3, 1.5, 2] as [any Sendable])
        #expect(out as? [Double] == [1.5, 2.0, 3.0])
    }

    @Test("A list of unsortable things comes back unchanged, not wrong")
    func leavesUnsortableAlone() async throws {
        let input: [any Sendable] = ["a", 1, true]
        let out = try await sort(input)
        #expect((out as? [any Sendable])?.count == 3)
    }
}
