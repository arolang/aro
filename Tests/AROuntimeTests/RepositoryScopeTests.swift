// ============================================================
// RepositoryScopeTests.swift
// ARO Runtime — who a repository belongs to
// ARO-0094, GitLab #885
// ============================================================
//
// The rule these tests exist to defend: a caller-scoped repository that cannot
// resolve its caller must FAIL, never fall back. Falling back to the
// application-wide repository turns a missing session into one user reading
// another's data, and an empty result would be just as wrong in the other
// direction — `Store` would write where nobody reads. Either way no test
// catches it, which is why the failure has to be loud.

import Testing
@testable import ARORuntime

@Suite("Repository scope (ARO-0094)", .serialized)
struct RepositoryScopeTests {

    private func registry() -> RepositoryScopeRegistry {
        let r = RepositoryScopeRegistry()
        return r
    }

    // MARK: - Parsing

    @Test("The three scopes parse, and nothing else does")
    func scopeParsing() {
        #expect(RepositoryScope.parse("application") == .application)
        #expect(RepositoryScope.parse("session") == .session)
        #expect(RepositoryScope.parse("connection") == .connection)
        #expect(RepositoryScope.parse("  SESSION  ") == .session, "case and space are not the point")
        #expect(RepositoryScope.parse("user") == nil)
        #expect(RepositoryScope.parse("") == nil)
    }

    @Test("Only application needs no caller")
    func needsCaller() {
        #expect(!RepositoryScope.application.needsCaller)
        #expect(RepositoryScope.session.needsCaller)
        #expect(RepositoryScope.connection.needsCaller)
    }

    // MARK: - Declaration

    @Test("An undeclared repository is application-scoped")
    func undeclaredIsApplication() {
        // Every repository was application-scoped before ARO-0094, and every
        // program that does not use Declare must keep behaving exactly as it did.
        let r = registry()
        #expect(r.scope(of: "cart-repository") == .application)
        #expect(!r.isDeclared("cart-repository"))
    }

    @Test("Declaring the same scope twice is fine")
    func idempotentDeclaration() {
        let r = registry()
        #expect(r.declare("cart-repository", scope: .session).isSuccess)
        #expect(r.declare("cart-repository", scope: .session).isSuccess)
        #expect(r.scope(of: "cart-repository") == .session)
    }

    @Test("Two declarations that disagree are refused")
    func conflictingDeclaration() {
        // One of the two statements is wrong. Picking either silently would
        // make the wrong one look correct — and if the wrong one is the wider
        // scope, that is the leak.
        let r = registry()
        #expect(r.declare("cart-repository", scope: .session).isSuccess)
        let second = r.declare("cart-repository", scope: .application)
        #expect(!second.isSuccess)
        #expect(r.scope(of: "cart-repository") == .session, "the first declaration stands")
    }

    // MARK: - Resolution — the part that must not fall back

    @Test("An application repository resolves for any caller, including none")
    func applicationAlwaysResolves() {
        let r = registry()
        r.declare("catalogue-repository", scope: .application)
        for caller: CallerIdentity in [.none,
                                       .connection(id: "c1"),
                                       .session(id: "s1", connection: "c1")] {
            #expect(r.resolve(repository: "catalogue-repository", caller: caller).value == "",
                    "an application repository keys exactly as it did before ARO-0094")
        }
    }

    @Test("A session repository resolves only for a session")
    func sessionNeedsASession() {
        let r = registry()
        r.declare("cart-repository", scope: .session)
        #expect(r.resolve(repository: "cart-repository",
                          caller: .session(id: "s1", connection: nil)).value == "session:s1")
        // A bare connection is not an identity. This is the TCP peer, and it
        // must not reach a logged-in user's cart.
        #expect(!r.resolve(repository: "cart-repository",
                           caller: .connection(id: "c1")).isSuccess)
        #expect(!r.resolve(repository: "cart-repository", caller: .none).isSuccess)
    }

    @Test("A connection repository resolves for a connection, and for a session that has one")
    func connectionResolution() {
        let r = registry()
        r.declare("partial-repository", scope: .connection)
        #expect(r.resolve(repository: "partial-repository",
                          caller: .connection(id: "c1")).value == "conn:c1")
        // A promoted socket is both: it has a session AND the connection it
        // arrived on, so connection-scoped data stays with the socket.
        #expect(r.resolve(repository: "partial-repository",
                          caller: .session(id: "s1", connection: "c9")).value == "conn:c9")
        // An HTTP request has a session but no connection the program can see.
        #expect(!r.resolve(repository: "partial-repository",
                           caller: .session(id: "s1", connection: nil)).isSuccess)
        #expect(!r.resolve(repository: "partial-repository", caller: .none).isSuccess)
    }

    @Test("Two sessions never share a partition")
    func sessionsAreSeparate() {
        let r = registry()
        r.declare("cart-repository", scope: .session)
        let a = r.resolve(repository: "cart-repository", caller: .session(id: "alice", connection: nil)).value
        let b = r.resolve(repository: "cart-repository", caller: .session(id: "bob", connection: nil)).value
        #expect(a != b)
        #expect(a == "session:alice")
        #expect(b == "session:bob")
    }

    @Test("The failure names the repository, the scope and why")
    func errorIsLegible() {
        // ARO-0006: the runtime reconstructs what failed. "cart-repository is
        // session-scoped and this feature set has no caller" is actionable;
        // an empty list is not.
        let r = registry()
        r.declare("cart-repository", scope: .session)
        guard case .failure(let error) = r.resolve(repository: "cart-repository", caller: .none) else {
            Issue.record("expected a failure"); return
        }
        let text = error.description
        #expect(text.contains("cart-repository"))
        #expect(text.contains("session"))
        #expect(text.contains("no caller"))
    }
}

// Small conveniences so the assertions above read as assertions.
private extension Result where Success == String, Failure == RepositoryScopeError {
    var value: String? { if case .success(let v) = self { return v }; return nil }
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

private extension Result where Success == Void, Failure == RepositoryScopeError {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
