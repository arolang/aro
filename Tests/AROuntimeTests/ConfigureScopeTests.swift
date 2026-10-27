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
//
// Every test here declares into a registry of its own, handed to the action
// through a `RuntimeContainer`. Declaring into `RepositoryScopeRegistry.shared`
// and clearing it either side made these tests race `CallerScopedStorageTests`,
// which was doing the same to the same object (GitLab #890).

import Testing
@testable import ARORuntime
import AROParser

@Suite("Repository scope through Configure (GitLab #886)", .serialized)
struct ConfigureScopeTests {

    /// A container nothing else in the process shares: its own scope registry,
    /// and its own storage so a `ttl` set here is not a `ttl` set everywhere.
    private func isolated() -> (RuntimeContainer, RepositoryScopeRegistry) {
        let registry = RepositoryScopeRegistry()
        return (RuntimeContainer(repositoryStorage: InMemoryRepositoryStorage(),
                                 repositoryScopes: registry), registry)
    }

    private func configure(
        in container: RuntimeContainer,
        repository: String = "cart-repository",
        specifier: String?,
        payload: any Sendable,
        bindAs: String = "_with_"
    ) async throws {
        let context = RuntimeContext(featureSetName: "Application-Start",
                                     businessActivity: "Shop",
                                     container: container)
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
        let (container, scopes) = isolated()
        try await configure(in: container, specifier: "scope", payload: "session")
        #expect(scopes.scope(of: "cart-repository") == .session)
    }

    @Test("The object form sets several properties at once")
    func objectForm() async throws {
        // The spelling that exists because two Configure statements on one
        // repository collide — this is how you set scope and ttl together.
        let (container, scopes) = isolated()
        try await configure(in: container, specifier: nil,
                            payload: ["scope": "connection", "ttl": 3600] as [String: any Sendable])
        #expect(scopes.scope(of: "cart-repository") == .connection)
    }

    @Test("A compiled binary binds the payload elsewhere, and it still works")
    func compiledBinding() async throws {
        // `with { … }` is the statement's value source, so the interpreter
        // binds it to `_with_` *and* `_expression_` while compiled code binds
        // only `_expression_`. Reading one name worked under `aro run` and
        // silently did nothing under `aro build` (ARO-0094).
        let (container, scopes) = isolated()
        try await configure(in: container, specifier: nil,
                            payload: ["scope": "session"] as [String: any Sendable],
                            bindAs: "_expression_")
        #expect(scopes.scope(of: "cart-repository") == .session)
    }

    @Test("An unknown scope is refused, and nothing is registered")
    func unknownScope() async {
        let (container, scopes) = isolated()
        await #expect(throws: (any Error).self) {
            try await configure(in: container, specifier: "scope", payload: "user")
        }
        #expect(!scopes.isDeclared("cart-repository"))
    }

    @Test("An unknown repository property is refused rather than ignored")
    func unknownProperty() async {
        // Silently dropping it is how `{ scpoe: "session" }` becomes an
        // application-wide repository nobody notices.
        let (container, _) = isolated()
        await #expect(throws: (any Error).self) {
            try await configure(in: container, specifier: nil,
                                payload: ["scpoe": "session"] as [String: any Sendable])
        }
    }

    @Test("Two Configure statements that disagree are refused")
    func conflictingScope() async throws {
        let (container, scopes) = isolated()
        try await configure(in: container, specifier: "scope", payload: "session")
        await #expect(throws: (any Error).self) {
            try await configure(in: container, specifier: "scope", payload: "application")
        }
        #expect(scopes.scope(of: "cart-repository") == .session,
                "the first declaration stands")
    }

    @Test("ttl and maxSize still work, and do not clear each other")
    func storageSettingsUnaffected() async throws {
        // The fold must not disturb what `Configure` already did for
        // repositories (ARO-0035).
        let (container, scopes) = isolated()
        try await configure(in: container, repository: "cache-repository",
                            specifier: "ttl", payload: 60)
        try await configure(in: container, repository: "other-repository",
                            specifier: "maxSize", payload: 10)
        #expect(scopes.scope(of: "cache-repository") == .application)
    }
}
