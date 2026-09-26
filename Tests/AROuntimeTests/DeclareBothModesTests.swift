// ============================================================
// DeclareBothModesTests.swift
// ARO Runtime — `Declare` finds its scope whichever mode bound it
// ARO-0094 §3.1, GitLab #885
// ============================================================
//
// `Declare the <cart-repository> with { scope: "session" }.` parses as
// `with the <_expression_>`: the map has nowhere else to go, so it is the
// statement's value source rather than a `with` modifier. The two modes then
// bind it under different names — the interpreter under both `_with_` and
// `_expression_`, compiled code under `_expression_` only.
//
// Reading only `_with_` therefore worked under `aro run` and silently did
// nothing under `aro build`: the action never saw its properties, the scope
// was never registered, and every statement governed by it read the
// application-wide repository. Nothing failed; the data was just wrong.
//
// The fix is in the action rather than in codegen, and that is the
// interesting part. Teaching `ModifierBinder` to bind `_with_` for this shape
// also works — and breaks `Examples/MedallionPipeline`, because it sets
// `_with_` for *every* statement of this shape, `Store` reads the presence of
// `_with_` as "the payload is the value" (GitLab #515), and inside a
// `for each` body the compiled path does not emit the per-statement transient
// sweep. A `Create … with { … }` then leaks into the `Store` on the next line
// and six bronze rows become one.

import Testing
@testable import ARORuntime
import AROParser

@Suite("Declare reads its properties in both modes (ARO-0094)", .serialized)
struct DeclareBothModesTests {

    private func declare(boundAs name: String) async throws -> RepositoryScope {
        RepositoryScopeRegistry.shared.reset()
        let context = RuntimeContext(featureSetName: "Application-Start", businessActivity: "Shop")
        context.bind(name, value: ["scope": "session"] as [String: any Sendable])
        _ = try await DeclareAction().execute(
            result: ResultDescriptor(base: "cart-repository", specifiers: [],
                                     span: SourceSpan(at: SourceLocation())),
            object: ObjectDescriptor(preposition: .with, base: "_expression_", specifiers: [],
                                     span: SourceSpan(at: SourceLocation())),
            context: context)
        return RepositoryScopeRegistry.shared.scope(of: "cart-repository")
    }

    @Test("From _with_, as the interpreter binds it")
    func readsWith() async throws {
        #expect(try await declare(boundAs: "_with_") == .session)
        RepositoryScopeRegistry.shared.reset()
    }

    @Test("From _expression_, as a compiled binary binds it")
    func readsExpression() async throws {
        // This is the one that was silently doing nothing.
        #expect(try await declare(boundAs: "_expression_") == .session)
        RepositoryScopeRegistry.shared.reset()
    }

    @Test("From _literal_, for a bare literal payload")
    func readsLiteral() async throws {
        #expect(try await declare(boundAs: "_literal_") == .session)
        RepositoryScopeRegistry.shared.reset()
    }

    @Test("With the properties nowhere, the statement fails rather than defaulting")
    func missingPropertiesFail() async {
        RepositoryScopeRegistry.shared.reset()
        let context = RuntimeContext(featureSetName: "Application-Start", businessActivity: "Shop")
        await #expect(throws: (any Error).self) {
            _ = try await DeclareAction().execute(
                result: ResultDescriptor(base: "cart-repository", specifiers: [],
                                         span: SourceSpan(at: SourceLocation())),
                object: ObjectDescriptor(preposition: .with, base: "_expression_", specifiers: [],
                                         span: SourceSpan(at: SourceLocation())),
                context: context)
        }
        // And nothing was registered — a half-applied declaration is worse
        // than none, because it reads as deliberate.
        #expect(!RepositoryScopeRegistry.shared.isDeclared("cart-repository"))
    }
}
