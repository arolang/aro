// ============================================================
// ConfigureScopeTests.swift
// ARO Runtime — a repository's scope is a Configure setting
// ARO-0094, GitLab #886
// ============================================================
//
// `Declare` and `Configure` were two verbs for one idea: set a property of a
// named thing, at startup, with an object of properties. #886 folded them, so
// a repository's scope sits beside its `ttl` and `maxSize` — which is where a
// reader looks for "how should this repository behave?".
//
// Both spellings exist, and the second is not sugar. `Configure` binds its
// subject, so two statements naming one repository are an immutable rebind
// (the existing hint says as much). Setting scope *and* ttl therefore has to
// be one statement.

import Testing
@testable import ARORuntime
import AROParser

@Suite("Repository scope through Configure (GitLab #886)", .serialized)
struct ConfigureScopeTests {

    private func configure(
        repository: String = "cart-repository",
        specifier: String?,
        payload: any Sendable,
        bindAs: String = "_with_"
    ) async throws {
        let context = RuntimeContext(featureSetName: "Application-Start", businessActivity: "Shop")
        context.bind(bindAs, value: payload)
        _ = try await ConfigureAction().execute(
            result: ResultDescriptor(base: repository,
                                     specifiers: specifier.map { [$0] } ?? [],
                                     span: SourceSpan(at: SourceLocation())),
            object: ObjectDescriptor(preposition: .with, base: "_expression_", specifiers: [],
                                     span: SourceSpan(at: SourceLocation())),
            context: context)
    }

    @Test("The specifier form sets the scope")
    func specifierForm() async throws {
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        try await configure(specifier: "scope", payload: "session")
        #expect(RepositoryScopeRegistry.shared.scope(of: "cart-repository") == .session)
    }

    @Test("The object form sets several properties at once")
    func objectForm() async throws {
        // The spelling that exists because two Configure statements on one
        // repository collide — this is how you set scope and ttl together.
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        try await configure(specifier: nil,
                            payload: ["scope": "connection", "ttl": 3600] as [String: any Sendable])
        #expect(RepositoryScopeRegistry.shared.scope(of: "cart-repository") == .connection)
    }

    @Test("A compiled binary binds the payload elsewhere, and it still works")
    func compiledBinding() async throws {
        // `with { … }` is the statement's value source, so the interpreter
        // binds it to `_with_` *and* `_expression_` while compiled code binds
        // only `_expression_`. Reading one name worked under `aro run` and
        // silently did nothing under `aro build` (ARO-0094).
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        try await configure(specifier: nil,
                            payload: ["scope": "session"] as [String: any Sendable],
                            bindAs: "_expression_")
        #expect(RepositoryScopeRegistry.shared.scope(of: "cart-repository") == .session)
    }

    @Test("An unknown scope is refused, and nothing is registered")
    func unknownScope() async {
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        await #expect(throws: (any Error).self) {
            try await configure(specifier: "scope", payload: "user")
        }
        #expect(!RepositoryScopeRegistry.shared.isDeclared("cart-repository"))
    }

    @Test("An unknown repository property is refused rather than ignored")
    func unknownProperty() async {
        // Silently dropping it is how `{ scpoe: "session" }` becomes an
        // application-wide repository nobody notices.
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        await #expect(throws: (any Error).self) {
            try await configure(specifier: nil,
                                payload: ["scpoe": "session"] as [String: any Sendable])
        }
    }

    @Test("Two Configure statements that disagree are refused")
    func conflictingScope() async throws {
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        try await configure(specifier: "scope", payload: "session")
        await #expect(throws: (any Error).self) {
            try await configure(specifier: "scope", payload: "application")
        }
        #expect(RepositoryScopeRegistry.shared.scope(of: "cart-repository") == .session,
                "the first declaration stands")
    }

    @Test("ttl and maxSize still work, and do not clear each other")
    func storageSettingsUnaffected() async throws {
        // The fold must not disturb what `Configure` already did for
        // repositories (ARO-0035).
        RepositoryScopeRegistry.shared.reset()
        defer { RepositoryScopeRegistry.shared.reset() }
        try await configure(repository: "cache-repository", specifier: "ttl", payload: 60)
        try await configure(repository: "other-repository", specifier: "maxSize", payload: 10)
        #expect(RepositoryScopeRegistry.shared.scope(of: "cache-repository") == .application)
    }
}
