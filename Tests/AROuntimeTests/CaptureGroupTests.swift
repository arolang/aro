// ============================================================
// CaptureGroupTests.swift
// ARO Runtime — regex capture groups
// ARO-0037 §7, GitLab #858
// ============================================================
//
// A pattern with named groups parsed and matched, and then nothing could read
// the groups back. The workaround in the books was four `Split` statements for
// one match, which is slower and wrong at the edges.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Regex capture groups (#858)")
struct CaptureGroupTests {

    private func compute(
        _ qualifier: String,
        on input: any Sendable,
        by pattern: String,
        flags: String = ""
    ) async throws -> any Sendable {
        let span = SourceSpan(at: SourceLocation())
        let action = ComputeAction()
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: input)
        context.bind("_by_pattern_", value: pattern)
        context.bind("_by_flags_", value: flags)
        return try await action.execute(
            result: ResultDescriptor(base: "out", specifiers: [qualifier], span: span),
            object: ObjectDescriptor(preposition: .from, base: "input",
                                     specifiers: [], span: span),
            context: context)
    }

    private func record(_ value: any Sendable) -> [String: any Sendable]? {
        value as? [String: any Sendable]
    }

    // MARK: - captures

    @Test("named groups come back under their names")
    func namedGroups() async throws {
        let value = try await compute("captures", on: "host=example.com",
                                      by: #"(?<key>\w+)=(?<value>\S+)"#)
        let parts = record(value)
        #expect(parts?["key"] as? String == "host")
        #expect(parts?["value"] as? String == "example.com")
    }

    @Test("the whole match is under `match`")
    func wholeMatch() async throws {
        let value = try await compute("captures", on: "prefix host=example.com suffix",
                                      by: #"(?<key>\w+)=(?<value>\S+)"#)
        #expect(record(value)?["match"] as? String == "host=example.com")
    }

    @Test("groups are also numbered, named or not")
    func numberedGroups() async throws {
        // A pattern mixes the two freely, and a reader should not have to
        // count parentheses to learn that `key` is also `1`.
        let value = try await compute("captures", on: "host=example.com",
                                      by: #"(?<key>\w+)=(\S+)"#)
        let parts = record(value)
        #expect(parts?["1"] as? String == "host")
        #expect(parts?["2"] as? String == "example.com")
        #expect(parts?["key"] as? String == "host")
    }

    @Test("captures binds the FIRST match")
    func firstMatchOnly() async throws {
        let value = try await compute("captures", on: "a=1 b=2",
                                      by: #"(?<key>\w+)=(?<value>\d+)"#)
        #expect(record(value)?["key"] as? String == "a")
    }

    @Test("a non-match binds an empty record, and does not fail")
    func nonMatchIsEmptyRecord() async throws {
        // The same call ARO-0006 makes for a Retrieve that matches nothing
        // (GitLab #835): finding nothing is an answer, and the program guards
        // on it rather than being thrown out of.
        let value = try await compute("captures", on: "nothing here",
                                      by: #"(?<key>\w+)=(?<value>.*)"#)
        #expect(record(value)?.isEmpty == true)
    }

    @Test("a group that did not participate is absent, not empty")
    func unmatchedAlternativeIsAbsent() async throws {
        let value = try await compute("captures", on: "left",
                                      by: #"(?<a>left)|(?<b>right)"#)
        let parts = record(value)
        #expect(parts?["a"] as? String == "left")
        #expect(parts?["b"] == nil)
    }

    @Test("flags reach the regex")
    func caseInsensitiveFlag() async throws {
        let value = try await compute("captures", on: "HOST=example.com",
                                      by: #"(?<key>host)=(?<value>\S+)"#, flags: "i")
        #expect(record(value)?["key"] as? String == "HOST")
    }

    // MARK: - all-captures

    @Test("all-captures binds one record per match, in order")
    func everyMatch() async throws {
        let value = try await compute("all-captures", on: "a=1 b=2 c=3",
                                      by: #"(?<key>\w+)=(?<value>\d+)"#)
        let matches = value as? [any Sendable]
        #expect(matches?.count == 3)
        #expect(record(matches?[0] ?? "")?["key"] as? String == "a")
        #expect(record(matches?[2] ?? "")?["value"] as? String == "3")
    }

    @Test("all-captures binds an empty list when nothing matches")
    func noMatchesIsEmptyList() async throws {
        let value = try await compute("all-captures", on: "nothing here",
                                      by: #"(?<key>\w+)=(?<value>\d+)"#)
        #expect((value as? [any Sendable])?.isEmpty == true)
    }

    // MARK: - Missing pattern

    @Test("no `by` clause is an error naming what is missing")
    func missingPatternIsReported() async throws {
        let span = SourceSpan(at: SourceLocation())
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: "a=1")
        await #expect(throws: (any Error).self) {
            _ = try await ComputeAction().execute(
                result: ResultDescriptor(base: "out", specifiers: ["captures"], span: span),
                object: ObjectDescriptor(preposition: .from, base: "input",
                                         specifiers: [], span: span),
                context: context)
        }
    }

    // MARK: - The catalogs agree

    @Test("the parser's catalog knows both qualifiers")
    func checkTimeCatalogAgrees() {
        // `aro check` never loads the runtime, so the names live in two
        // places; a green check has to mean the qualifier exists.
        #expect(ComputeQualifierCatalog.builtIns.contains("captures"))
        #expect(ComputeQualifierCatalog.builtIns.contains("all-captures"))
    }
}
