// ============================================================
// ComputeQualifierTests.swift
// ARO Runtime — collection/text qualifiers + the closed namespace
// GitLab #486
// ============================================================
//
// Two things are under test here.
//
// The seven qualifiers `aro ask` kept inventing — `sum`, `unique`,
// `sha256`, `avg`, `random`, `lines`, `join` — now exist, because a
// model reaching for the same name 2,652 times across the corpus is
// evidence that the three-statement idiom they replace was the wrong
// shape, not that the model was careless.
//
// And the reason nobody noticed: an unregistered qualifier used to
// return its input unchanged. `Compute the <total: lines> from
// <content>` compiled, checked clean, ran green, and logged the file
// body where a line count belonged. The namespace is closed, so an
// unrecognised name is now an error.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Compute qualifiers (#486)")
struct ComputeQualifierTests {

    private func descriptors(
        qualifier: String,
        objectBase: String = "input"
    ) -> (ResultDescriptor, ObjectDescriptor) {
        let span = SourceSpan(at: SourceLocation())
        return (
            ResultDescriptor(base: "out", specifiers: [qualifier], span: span),
            ObjectDescriptor(preposition: .from, base: objectBase,
                             specifiers: [], span: span)
        )
    }

    private func compute(
        _ qualifier: String,
        on input: any Sendable,
        with parameters: (any Sendable)? = nil
    ) async throws -> any Sendable {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        if let parameters { context.bind("_with_", value: parameters) }
        let (result, object) = descriptors(qualifier: qualifier)
        return try await action.execute(result: result, object: object,
                                        context: context)
    }

    // MARK: - lines

    @Test("lines splits text into a list")
    func linesSplits() async throws {
        let value = try await compute("lines", on: "a\nb\nc\n")
        #expect(value as? [String] == ["a", "b", "c"])
    }

    @Test("lines does not invent a trailing empty line")
    func linesNoPhantomTail() async throws {
        // This is the whole point of having the primitive. The
        // hand-rolled trim → Split → length idiom answers 4 for a
        // 3-line file if you forget the trim, and the reference
        // answer in the issue has to spell that out.
        let withNewline = try await compute("lines", on: "a\nb\nc\n")
        let without = try await compute("lines", on: "a\nb\nc")
        #expect((withNewline as? [String])?.count == 3)
        #expect((without as? [String])?.count == 3)
    }

    @Test("lines treats CRLF as one terminator")
    func linesHandlesCRLF() async throws {
        let value = try await compute("lines", on: "a\r\nb\r\n")
        #expect(value as? [String] == ["a", "b"])
    }

    @Test("lines splits the same way on every platform")
    func linesMixedTerminators() async throws {
        // `\r\n` is one grapheme cluster, so splitting on the "\n"
        // *substring* is grapheme-aware on Linux Foundation (no match
        // at all → one giant line) and UTF-16-aware on Darwin (splits,
        // leaving a stray `\r`). The split has to be over Characters
        // for the two runners to agree — this is the case that went
        // green locally and red in CI.
        let value = try await compute("lines", on: "a\r\nb\nc\rd\n")
        #expect(value as? [String] == ["a", "b", "c", "d"])
        let lines = try #require(value as? [String])
        #expect(lines.allSatisfy { !$0.contains("\r") && !$0.contains("\n") })
    }

    @Test("lines of empty text is an empty list")
    func linesEmpty() async throws {
        let value = try await compute("lines", on: "")
        #expect((value as? [any Sendable])?.isEmpty == true)
    }

    @Test("counting lines is lines then length")
    func lineCountIdiom() async throws {
        let lines = try await compute("lines", on: "one\ntwo\nthree\n")
        let count = try await compute("length", on: lines)
        #expect(count as? Int == 3)
    }

    // MARK: - sum / avg

    @Test("sum of integers stays an integer")
    func sumIntegers() async throws {
        // 6, not 6.0 — the logged output is what the user sees.
        let value = try await compute("sum", on: [1, 2, 3] as [any Sendable])
        #expect(value as? Int == 6)
    }

    @Test("sum of mixed numbers is a double")
    func sumMixed() async throws {
        let value = try await compute("sum", on: [1, 2.5] as [any Sendable])
        #expect(value as? Double == 3.5)
    }

    @Test("sum reads numeric strings")
    func sumStrings() async throws {
        let value = try await compute("sum", on: ["1", "2", "3"] as [any Sendable])
        #expect(value as? Int == 6 || value as? Double == 6.0)
    }

    @Test("sum of an empty collection is zero")
    func sumEmpty() async throws {
        let value = try await compute("sum", on: [any Sendable]())
        #expect(value as? Int == 0)
    }

    @Test("sum rejects non-numeric elements")
    func sumRejectsText() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await compute("sum", on: ["a", "b"] as [any Sendable])
        }
    }

    @Test("avg is the arithmetic mean")
    func average() async throws {
        let value = try await compute("avg", on: [1, 2, 3, 4] as [any Sendable])
        #expect(value as? Double == 2.5)
    }

    @Test("average is an alias of avg")
    func averageAlias() async throws {
        let value = try await compute("average", on: [2, 4] as [any Sendable])
        #expect(value as? Double == 3.0)
    }

    @Test("avg of an empty collection is an error, not zero")
    func averageEmpty() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await compute("avg", on: [any Sendable]())
        }
    }

    // MARK: - unique

    @Test("unique keeps first-seen order")
    func uniqueOrder() async throws {
        let value = try await compute(
            "unique", on: ["b", "a", "b", "c", "a"] as [any Sendable])
        #expect(value as? [String] == ["b", "a", "c"])
    }

    @Test("unique dedupes numbers")
    func uniqueNumbers() async throws {
        let value = try await compute("unique", on: [1, 2, 1, 3] as [any Sendable])
        #expect((value as? [any Sendable])?.count == 3)
    }

    @Test("unique on a string dedupes characters")
    func uniqueString() async throws {
        let value = try await compute("unique", on: "aabbcc")
        #expect(value as? String == "abc")
    }

    // MARK: - join

    @Test("join concatenates without a separator")
    func joinDefault() async throws {
        let value = try await compute("join", on: ["a", "b", "c"] as [any Sendable])
        #expect(value as? String == "abc")
    }

    @Test("join takes a separator from the with clause")
    func joinSeparator() async throws {
        let value = try await compute(
            "join", on: ["a", "b", "c"] as [any Sendable],
            with: ["separator": ", "] as [String: any Sendable])
        #expect(value as? String == "a, b, c")
    }

    @Test("join accepts a bare separator")
    func joinBareSeparator() async throws {
        let value = try await compute(
            "join", on: ["a", "b"] as [any Sendable], with: "-")
        #expect(value as? String == "a-b")
    }

    @Test("join renders non-string elements")
    func joinNumbers() async throws {
        let value = try await compute(
            "join", on: [1, 2, 3] as [any Sendable],
            with: ["separator": "+"] as [String: any Sendable])
        #expect(value as? String == "1+2+3")
    }

    // MARK: - sha256

    @Test("sha256 matches the known digest of \"abc\"")
    func sha256KnownValue() async throws {
        let value = try await compute("sha256", on: "abc")
        #expect(value as? String
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("sha256 and hash are the same operation")
    func sha256IsHash() async throws {
        let viaAlias = try await compute("sha256", on: "hello")
        let viaHash = try await compute("hash", on: "hello")
        #expect(viaAlias as? String == viaHash as? String)
    }

    // MARK: - random

    @Test("random picks an element of the collection")
    func randomElement() async throws {
        let pool: [any Sendable] = ["a", "b", "c"]
        for _ in 0..<20 {
            let value = try await compute("random", on: pool)
            #expect(["a", "b", "c"].contains(value as? String ?? ""))
        }
    }

    @Test("random on a whole number stays below the bound")
    func randomBound() async throws {
        for _ in 0..<20 {
            let value = try await compute("random", on: 10)
            let n = try #require(value as? Int)
            #expect(n >= 0 && n < 10)
        }
    }

    @Test("random of an empty collection is an error")
    func randomEmpty() async throws {
        await #expect(throws: (any Error).self) {
            _ = try await compute("random", on: [any Sendable]())
        }
    }

    // MARK: - The closed namespace

    @Test("An unregistered qualifier is an error, not the input")
    func unknownQualifierThrows() async throws {
        // The reported bug: this used to return "file contents"
        // unchanged and exit [OK].
        await #expect(throws: (any Error).self) {
            _ = try await compute("jsonify", on: "file contents")
        }
    }

    @Test("Invented names from the corpus all fail now",
          arguments: ["jsonify", "merge", "exitCode", "sort", "filter",
                      "split", "reverse", "linecount"])
    func inventedNamesThrow(name: String) async throws {
        await #expect(throws: (any Error).self) {
            _ = try await compute(name, on: "value")
        }
    }

    @Test("A result with no qualifier still passes through")
    func noQualifierIsIdentity() async throws {
        // `Compute the <total> from <a> + <b>` has no specifier and
        // resolves to `identity`; only *explicit* qualifiers are
        // held to the closed namespace.
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "unchanged")
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "out", specifiers: [], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "input",
                                      specifiers: [], span: span)
        let value = try await action.execute(result: result, object: object,
                                             context: context)
        #expect(value as? String == "unchanged")
    }

    @Test("A date offset is still resolved, not rejected")
    func dateOffsetStillWorks() async throws {
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "2026-01-01T00:00:00Z")
        let (result, object) = descriptors(qualifier: "+1d")
        let value = try await action.execute(result: result, object: object,
                                             context: context)
        #expect(value is ARODate)
    }

    @Test("The error names the qualifier and suggests a near miss")
    func errorSuggestsClosestName() async throws {
        do {
            _ = try await compute("uppercse", on: "hello")
            Issue.record("expected a thrown error")
        } catch let error as ActionError {
            #expect(error.description.contains("uppercse"))
            #expect(error.description.contains("uppercase"))
        }
    }

    // MARK: - Catalog integrity

    @Test("Every built-in qualifier is discoverable through the registry")
    func registryMatchesRuntime() {
        // The registry used to carry its own hand-written list, which
        // drifted to 15 entries while the runtime grew to 25 — so
        // `aro actions --qualifiers` under-reported what exists, and
        // any catalog built from it inherited the blind spot.
        let registered = Set(
            QualifierRegistry.shared.allRegistrations()
                .filter { $0.namespace == "_builtin" }
                .map(\.qualifier))
        let implemented = Set(ComputeAction.builtInQualifiers.map(\.name))
        #expect(registered == implemented)
        #expect(implemented.count >= 33)
    }

    @Test("The parser's catalog and the runtime's table are the same set")
    func parserCatalogMatchesRuntime() {
        // GitLab #465. `aro check` never loads the runtime, so the
        // names it validates against live in AROParser while the
        // implementations live here. Two lists is exactly the drift
        // that produced #486's blind spot, so the invariant is a
        // test: add a qualifier here without listing it in
        // `ComputeQualifierCatalog.builtIns` and the analyser starts
        // rejecting a qualifier that works — the failure this change
        // exists to prevent, in the opposite direction.
        let implemented = Set(ComputeAction.builtInQualifiers.map { $0.name.lowercased() })
        #expect(ComputeQualifierCatalog.builtIns == implemented)
    }

    @Test("Every catalogued qualifier actually resolves",
          arguments: ComputeAction.builtInQualifiers.map(\.name))
    func everyCatalogEntryResolves(name: String) async throws {
        // Guards against a catalog entry whose op was never wired up —
        // it would advertise a qualifier that then throws "unknown".
        // Input choice is deliberately permissive; a type mismatch is
        // fine, an *unknown qualifier* is not.
        do {
            _ = try await compute(name, on: "text")
        } catch let error as ActionError {
            if case .unknownComputation = error {
                Issue.record("catalogued qualifier '\(name)' does not resolve")
            }
        } catch {
            // Any other failure is a type/argument problem, not a
            // registration problem.
        }
    }
}
