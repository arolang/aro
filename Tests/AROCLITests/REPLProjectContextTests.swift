// ============================================================
// REPLProjectContextTests.swift
// AROCLITests — a session opened inside a project sees it (GitLab #691)
// ============================================================
//
// `aro repl` and `aro kernel` built a session that registered a filesystem
// service and a terminal service and stopped. No `openapi.yaml`, no `.store`
// seed data, no `templates/`, no project plugins, and none of the project's own
// feature sets — so a notebook opened inside a project could not exercise that
// project, and the course diverged from `aro run`.
//
// Each test builds a throwaway project on disk and asserts the one thing it
// contributes, because the failure mode is silent: nothing errored before, the
// session simply did not know.

import Testing
import Foundation
@testable import AROCLI
@testable import ARORuntime

@Suite("A REPL session inside a project (#691)", .serialized)
struct REPLProjectContextTests {

    /// A project directory that cleans up after itself.
    private func project(
        _ build: (URL) throws -> Void
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("aro-p691-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - What a project contributes

    @Test("A contract is registered")
    func contractIsRegistered() async throws {
        let root = try project { root in
            try write("""
            openapi: 3.0.3
            info: { title: Demo, version: 1.0.0 }
            paths:
              /greet:
                get:
                  operationId: greet
            """, to: root.appendingPathComponent("openapi.yaml"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(context.notes.contains { $0.contains("contract") })
        #expect(context.warnings.isEmpty, "\(context.warnings)")
    }

    @Test("`.store` rows are seeded, so a cell can Retrieve them")
    func storesAreSeeded() async throws {
        let repo = "p691" + UUID().uuidString.prefix(8).lowercased()
        let root = try project { root in
            try write("""
            - id: "1"
              name: Ada
            - id: "2"
              name: Linus
            """, to: root.appendingPathComponent("\(repo).store"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(context.notes.contains { $0.contains("stores: 2 row") },
                "\(context.notes)")

        // The rows are in the storage a cell reads, not merely counted.
        let rows = await InMemoryRepositoryStorage.shared.retrieve(
            from: "\(repo)-repository", businessActivity: "test", caller: "")
        #expect(rows.count == 2, "seeded rows are not retrievable")
    }

    @Test("A templates directory gets a service WITH an executor")
    func templatesAreUsable() async throws {
        // The executor is the half that is easy to miss: without it the
        // service finds the file and answers "Template executor not
        // configured", which is a worse failure than not registering at all.
        let root = try project { root in
            try write("Hello, {{ <who> }}!\n",
                      to: root.appendingPathComponent("templates/hi.tpl"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(context.notes.contains { $0.contains("templates") })

        let service = session.context.service(TemplateService.self)
        #expect(service != nil, "no template service registered")
    }

    @Test("The project's feature sets become callable")
    func featureSetsAreAdded() async throws {
        let root = try project { root in
            try write("""
            (DoubleIt: Action takes <n>) {
                Extract the <v> from the <input: n>.
                Compute the <d> from <v> * 2.
                Return an <OK: status> with { doubled: <d> }.
            }
            """, to: root.appendingPathComponent("main.aro"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(context.notes.contains { $0.contains("feature sets: 1") },
                "\(context.notes)")
    }

    // MARK: - What it must NOT do

    @Test("Application-Start is discovered and not executed")
    func lifecycleIsNotRun() async throws {
        // A session is not a run. Executing Application-Start would bind
        // ports and start watchers the moment a notebook window opened.
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("p691-ran-" + UUID().uuidString)
        let root = try project { root in
            try write("""
            (Application-Start: Demo) {
                Create the <text> with "booted".
                Write the <text> to the <file: "\(marker.path)">.
                Return an <OK: status> for the <startup>.
            }
            """, to: root.appendingPathComponent("main.aro"))
        }
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: marker)
        }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(context.notes.contains { $0.contains("lifecycle: 1") },
                "\(context.notes)")
        #expect(!FileManager.default.fileExists(atPath: marker.path),
                "Application-Start executed — a session must not boot the app")
    }

    // MARK: - Surviving a broken project

    @Test("A malformed contract is a warning, and the rest still loads")
    func aBrokenProjectStillGivesWhatItCan() async throws {
        // A session is a tool for finding out why something is broken, so it
        // has to survive the thing being broken.
        let root = try project { root in
            try write("this: is: not: a: contract\n\t- [",
                      to: root.appendingPathComponent("openapi.yaml"))
            try write("Hello!\n", to: root.appendingPathComponent("templates/hi.tpl"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: root.path, into: session)
        #expect(!context.warnings.isEmpty, "a malformed contract said nothing")
        #expect(context.notes.contains { $0.contains("templates") },
                "one broken item took the rest down with it")
    }

    @Test("A path that is not a directory is reported, not crashed on")
    func nonDirectoryIsReported() async throws {
        let session = REPLSession()
        let context = await REPLProjectContext.load(
            directory: "/definitely/not/here", into: session)
        #expect(context.notes.isEmpty)
        #expect(context.warnings.contains { $0.contains("not a directory") })
    }

    // MARK: - Discovery rules

    @Test("Sources are found at any depth, and plugin sources are not mined")
    func sourceDiscoveryFollowsTheApplicationRules() throws {
        let root = try project { root in
            try write("(A: Action) { Return an <OK: status> for the <x>. }",
                      to: root.appendingPathComponent("main.aro"))
            try write("(B: Action) { Return an <OK: status> for the <x>. }",
                      to: root.appendingPathComponent("sources/deep/b.aro"))
            // A plugin's own ARO belongs to the plugin, and `.build` holds
            // whatever a previous compile left behind.
            try write("(C: Action) { Return an <OK: status> for the <x>. }",
                      to: root.appendingPathComponent("Plugins/p/features/c.aro"))
            try write("(D: Action) { Return an <OK: status> for the <x>. }",
                      to: root.appendingPathComponent(".build/d.aro"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = try REPLProjectContext.sourceFiles(in: root)
            .map { $0.lastPathComponent }
        #expect(found.sorted() == ["b.aro", "main.aro"], "found \(found)")
    }

    @Test("Lifecycle names are recognised, ordinary ones are not")
    func lifecycleRecognition() {
        #expect(REPLProjectContext.isLifecycle("Application-Start"))
        #expect(REPLProjectContext.isLifecycle("Application-End"))
        #expect(REPLProjectContext.isLifecycle("application-end: error"))
        #expect(!REPLProjectContext.isLifecycle("listUsers"))
        #expect(!REPLProjectContext.isLifecycle("DoubleValue"))
    }
}
