// ============================================================
// LanguageGapRuntimeTests.swift
// ARORuntime — the gaps from GitLab #830, executed
// ============================================================
//
// The parser tests in `LanguageGapTests` prove the new spellings parse.
// These prove they *do* something: a guard that actually gates a publish,
// a default that actually wins, two copies that actually coexist.
//
// That distinction is the whole reason #830 exists. Every item in it
// parsed fine — `Extract … default "8080"` compiled, checked green, and
// bound the empty string. Parsing was never the problem.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Language gaps, executed (#830)", .serialized)
struct LanguageGapRuntimeTests {

    /// An engine carrying the file-system service `Copy` and `Move` need.
    private func run(_ source: String) async throws -> Response {
        let result = Compiler().compile(source)
        #expect(result.diagnostics.allSatisfy { $0.severity != .error },
                "unexpected errors: \(result.diagnostics.map(\.message))")
        let engine = ExecutionEngine()
        await engine.register(service: AROFileSystemService(eventBus: .shared) as FileSystemService)
        return try await engine.execute(result.analyzedProgram)
    }

    /// The string a program returned under `<value>`.
    private func value(_ response: Response) -> String? {
        response.data["value"]?.get()
    }

    // MARK: - Item 14: a guard that gates

    @Test("A true guard publishes")
    func trueGuardPublishes() async throws {
        let response = try await run("""
        (Application-Start: Scores) {
            Compute the <score> from 90.
            Publish as <high> <score> when <score> > 50.
            Return an <OK: status> with <high>.
        }
        """)
        #expect(response.status == "OK")
    }

    /// The name stays *unpublished*, not published with a sentinel — so a
    /// reader fails the way an absent binding always fails, rather than
    /// quietly seeing a placeholder.
    @Test("A false guard leaves the name unbound")
    func falseGuardPublishesNothing() async throws {
        let result = Compiler().compile("""
        (Application-Start: Scores) {
            Compute the <score> from 5.
            Publish as <high> <score> when <score> > 50.
            Log <high> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """)
        let engine = ExecutionEngine()
        await #expect(throws: (any Error).self) {
            try await engine.execute(result.analyzedProgram)
        }
    }

    // MARK: - Item 1: Extract … default

    @Test("An unset environment variable takes the default")
    func unsetEnvTakesDefault() async throws {
        let response = try await run("""
        (Application-Start: Config) {
            Extract the <value> from the <env: ARO_830_DEFINITELY_UNSET> default "8080".
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == "8080")
    }

    @Test("A set environment variable beats the default")
    func setEnvBeatsDefault() async throws {
        setenv("ARO_830_SET", "9090", 1)
        defer { unsetenv("ARO_830_SET") }
        let response = try await run("""
        (Application-Start: Config) {
            Extract the <value> from the <env: ARO_830_SET> default "8080".
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == "9090")
    }

    /// `PORT=` is a value somebody wrote, and it wins — the same rule the
    /// `default` operator follows for `false`, `0` and `""` (GitLab #547).
    /// Defaulting on falsiness is the footgun ARO declined once already.
    @Test("A set-but-empty variable is a value, not an absence")
    func emptyEnvIsAValue() async throws {
        setenv("ARO_830_EMPTY", "", 1)
        defer { unsetenv("ARO_830_EMPTY") }
        let response = try await run("""
        (Application-Start: Config) {
            Extract the <value> from the <env: ARO_830_EMPTY> default "8080".
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == "")
    }

    /// Nothing that worked before reads differently: with no `default`
    /// clause an unset variable is still the empty string.
    @Test("Without a default, an unset variable is still empty")
    func noDefaultStillEmpty() async throws {
        let response = try await run("""
        (Application-Start: Config) {
            Extract the <value> from the <env: ARO_830_DEFINITELY_UNSET> .
            Return an <OK: status> with <value>.
        }
        """)
        #expect(value(response) == "")
    }

    // MARK: - Item 13: two Copies in one feature set

    @Test("Copy binds the name the author chose, so two of them coexist")
    func twoCopiesInOneFeatureSet() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-830-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.txt")
        let b = dir.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        _ = try await run("""
        (Application-Start: Backups) {
            Copy the <first: "\(a.path)"> to the <destination: "\(dir.path)/a-copy.txt">.
            Copy the <second: "\(b.path)"> to the <destination: "\(dir.path)/b-copy.txt">.
            Return an <OK: status> for the <startup>.
        }
        """)

        #expect(FileManager.default.fileExists(atPath: dir.path + "/a-copy.txt"))
        #expect(FileManager.default.fileExists(atPath: dir.path + "/b-copy.txt"))
    }

    /// The old spelling is not a legacy path to be tolerated — it is the
    /// same rule, with `file` as the chosen name.
    @Test("The documented <file:> spelling still copies")
    func theOldSpellingStillWorks() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-830-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = dir.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: a)

        _ = try await run("""
        (Application-Start: Backups) {
            Copy the <file: "\(a.path)"> to the <destination: "\(dir.path)/copy.txt">.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(FileManager.default.fileExists(atPath: dir.path + "/copy.txt"))
    }

    // MARK: - Item 5: the operators, evaluated

    @Test("starts with / ends with / not in decide guards correctly")
    func affixAndMembershipGuards() async throws {
        let response = try await run("""
        (Application-Start: Guards) {
            Compute the <path> from "/api/users".
            Create the <banned> with ["spam"].
            Compute the <tag> from "news".
            Compute the <hit> from "yes" when <path> starts with "/api".
            Compute the <miss> from "no" when <path> starts with "/web".
            Compute the <tail> from "yes" when <path> ends with "users".
            Compute the <allowed> from "yes" when <tag> not in <banned>.
            Return an <OK: status> with { hit: <hit>, tail: <tail>, allowed: <allowed> }.
        }
        """)
        #expect(response.status == "OK")
    }

    // MARK: - Item 15: the statuses that were 200

    @Test("The four missing statuses reach the wire as themselves")
    func missingStatusesMapCorrectly() {
        #expect(HTTPStatusCatalog.code(for: "Unprocessable") == 422)
        #expect(HTTPStatusCatalog.code(for: "TooManyRequests") == 429)
        #expect(HTTPStatusCatalog.code(for: "MethodNotAllowed") == 405)
        #expect(HTTPStatusCatalog.code(for: "Unavailable") == 503)
    }

    /// The bug was two hard-coded switches that disagreed. Both now read
    /// the one catalog, and this asserts the compiled path's answer for
    /// every name the catalog knows.
    @Test("The compiled bridge agrees with the catalog on every name")
    func compiledBridgeAgreesWithCatalog() {
        for (name, code) in HTTPStatusCatalog.byName {
            #expect(HTTPStatusCatalog.code(for: name) == code)
            #expect(HTTPStatusCatalog.reason(for: code) == HTTPStatusCatalog.reasonPhrase[code])
        }
    }
}
