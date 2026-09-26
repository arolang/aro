// ============================================================
// RepositoryScopeAnalyzerTests.swift
// AROParser — scope mistakes `aro check` should catch
// ARO-0094 §7.2, GitLab #885
// ============================================================
//
// What makes these worth having: the errors here are the ones that would
// otherwise surface as a runtime failure on the first request that happens to
// reach the statement — which, for an admin route or an error path, can be
// weeks after deployment.

import Testing
@testable import AROParser

@Suite("Repository scope analysis (ARO-0094 §7.2)")
struct RepositoryScopeAnalyzerTests {

    private func parse(_ source: String) throws -> Program {
        try Parser(tokens: try Lexer.tokenize(source)).parse()
    }

    private func diagnose(_ source: String, scopes: [String: String]) throws -> [Diagnostic] {
        let program = try parse(source)
        let collector = DiagnosticCollector()
        RepositoryScopeAnalyzer.check(program, scopes: scopes, diagnostics: collector)
        return collector.diagnostics
    }

    // MARK: - Collecting declarations

    @Test("Declarations are read off the Declare statements")
    func collectsDeclarations() throws {
        let program = try parse("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: "session" }.
            Declare the <partial-repository> with { scope: "connection" }.
            Return an <OK: status> for the <startup>.
        }
        """)
        let found = RepositoryScopeAnalyzer.declarations(in: program)
        #expect(found.count == 2)
        #expect(found.contains { $0.repository == "cart-repository" && $0.scope == "session" })
        #expect(found.contains { $0.repository == "partial-repository" && $0.scope == "connection" })
    }

    @Test("A scope that is not one of the three is an error")
    func unknownScope() throws {
        let program = try parse("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: "user" }.
            Return an <OK: status> for the <startup>.
        }
        """)
        let collector = DiagnosticCollector()
        let scopes = RepositoryScopeAnalyzer.resolve(
            RepositoryScopeAnalyzer.declarations(in: program), diagnostics: collector)
        #expect(scopes.isEmpty)
        #expect(collector.errors.count == 1)
        #expect(collector.errors[0].message.contains("'user' is not a scope"))
    }

    @Test("A bare word scope is reported as a scope, not as a missing variable")
    func bareWordScope() throws {
        // ARO-0094 §3.1.1: `{ scope: session }` parses as a variable
        // reference, because a bare word is one everywhere else in ARO. Left
        // alone it fails at run time with "Undefined variable: session", which
        // says nothing about scopes. The analyzer reads the name and says what
        // is actually wrong.
        let program = try parse("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: session }.
            Return an <OK: status> for the <startup>.
        }
        """)
        let found = RepositoryScopeAnalyzer.declarations(in: program)
        #expect(found.first?.scope == "session")
    }

    @Test("Two declarations that disagree are an error, and the first stands")
    func conflictingDeclarations() throws {
        let program = try parse("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: "session" }.
            Declare the <cart-repository> with { scope: "application" }.
            Return an <OK: status> for the <startup>.
        }
        """)
        let collector = DiagnosticCollector()
        let scopes = RepositoryScopeAnalyzer.resolve(
            RepositoryScopeAnalyzer.declarations(in: program), diagnostics: collector)
        #expect(scopes["cart-repository"] == "session")
        #expect(collector.errors.count == 1)
        #expect(collector.errors[0].message.contains("session-scoped and application-scoped"))
    }

    @Test("Declaring the same scope twice is fine")
    func idempotentDeclaration() throws {
        let program = try parse("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: "session" }.
            Declare the <cart-repository> with { scope: "session" }.
            Return an <OK: status> for the <startup>.
        }
        """)
        let collector = DiagnosticCollector()
        _ = RepositoryScopeAnalyzer.resolve(
            RepositoryScopeAnalyzer.declarations(in: program), diagnostics: collector)
        #expect(collector.errors.isEmpty)
    }

    // MARK: - Uses that can never resolve

    @Test("A session repository in Application-Start can never have a session")
    func sessionRepositoryInApplicationStart() throws {
        let found = try diagnose("""
        (Application-Start: Shop) {
            Declare the <cart-repository> with { scope: "session" }.
            Store the <seed> into the <cart-repository>.
            Return an <OK: status> for the <startup>.
        }
        """, scopes: ["cart-repository": "session"])
        #expect(found.count == 1)
        #expect(found[0].severity == .error)
        #expect(found[0].message.contains("can never have a session"))
    }

    @Test("A session repository in a file watcher can never have a session")
    func sessionRepositoryInFileHandler() throws {
        let found = try diagnose("""
        (Import Rows: File Event Handler) {
            Store the <row> into the <cart-repository>.
            Return an <OK: status> for the <import>.
        }
        """, scopes: ["cart-repository": "session"])
        #expect(found.count == 1)
        #expect(found[0].message.contains("can never have a session"))
    }

    @Test("A connection repository on an HTTP route has no connection to use")
    func connectionRepositoryOnHTTPRoute() throws {
        let found = try diagnose("""
        (addToCart: Shop API) {
            Store the <item> into the <partial-repository>.
            Return a <Created: status> with <item>.
        }
        """, scopes: ["partial-repository": "connection"])
        #expect(found.count == 1)
        #expect(found[0].message.contains("no connection the program can see"))
    }

    // MARK: - Uses that are fine

    @Test("A socket handler touching a session repository is left to run time")
    func socketHandlerMayHaveBeenPromoted() throws {
        // `Attach` may have promoted this connection, and the analyzer cannot
        // know whether it did. Warning here would fire on every correct
        // promotion, which is how a useful diagnostic becomes one people
        // silence.
        let found = try diagnose("""
        (Handle Data Received: Socket Event Handler) {
            Store the <chunk> into the <cart-repository>.
            Return an <OK: status> for the <packet>.
        }
        """, scopes: ["cart-repository": "session"])
        #expect(found.isEmpty)
    }

    @Test("A session repository on an HTTP route is exactly what it is for")
    func sessionRepositoryOnHTTPRoute() throws {
        let found = try diagnose("""
        (addToCart: Shop API) {
            Store the <item> into the <cart-repository>.
            Return a <Created: status> with <item>.
        }
        """, scopes: ["cart-repository": "session"])
        #expect(found.isEmpty)
    }

    @Test("An application repository is unremarkable anywhere")
    func applicationRepositoryAnywhere() throws {
        let found = try diagnose("""
        (Application-Start: Shop) {
            Store the <seed> into the <catalogue-repository>.
            Return an <OK: status> for the <startup>.
        }
        """, scopes: ["catalogue-repository": "application"])
        #expect(found.isEmpty)
    }

    @Test("An undeclared repository is not analysed at all")
    func undeclaredIsSilent() throws {
        // Every repository was application-scoped before ARO-0094 and a
        // program that never declares one must see no new diagnostics.
        let found = try diagnose("""
        (Application-Start: Shop) {
            Store the <seed> into the <cart-repository>.
            Return an <OK: status> for the <startup>.
        }
        """, scopes: [:])
        #expect(found.isEmpty)
    }

    @Test("A user-defined action inherits its caller, so nothing is decidable")
    func userActionIsNotAnalysed() throws {
        let found = try diagnose("""
        (AddItem: Action takes <item>) {
            Store the <item> into the <cart-repository>.
            Return an <OK: status> with <item>.
        }
        """, scopes: ["cart-repository": "session"])
        #expect(found.isEmpty)
    }

    // MARK: - The catalogue

    @Test("The analyzer's scope names match the runtime's")
    func scopeNamesAgree() {
        // AROParser cannot import ARORuntime — `aro check` never loads it — so
        // the two lists are pinned here the way ComputeQualifierCatalog is
        // pinned to ComputeAction. Add a scope to one and this fails.
        #expect(RepositoryScopeAnalyzer.scopeNames == ["application", "connection", "session"])
    }
}
