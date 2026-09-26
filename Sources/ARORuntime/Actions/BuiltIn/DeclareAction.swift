// ============================================================
// DeclareAction.swift
// ARO Runtime — Declare the <x-repository> with { scope: "session" }.
// ARO-0094, GitLab #885
// ============================================================
//
// Scope is a property of the repository, not of the statement that touches it.
// A cart is per-user in every line of the program that reads or writes it, so
// saying so once is both less to write and impossible to get inconsistently
// wrong.
//
// The rejected alternative was a qualifier at each use site —
// `Store the <item> into the <cart-repository: session>.` — which reads well and
// matches how ARO qualifies everything else. It is not the default for one
// reason: the scope would be restated at every statement, so it could be
// omitted at one of them, and a forgotten `: session` silently reads the
// application-wide repository. That is another user's cart, with no error. A
// safety property that must be retyped correctly on every line is not one.
//
// (Whether this should be `Configure` rather than a second verb is GitLab #886.
// The surface here is deliberately one action and one property, so a rename is
// cheap if that discussion says so.)

import Foundation
import AROParser

/// `Declare the <cart-repository> with { scope: "session" }.`
public struct DeclareAction: ActionImplementation {

    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["declare"]
    public static let validPrepositions: Set<Preposition> = [.with, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        // `Declare the <cart-repository> with { … }` — the repository is the
        // *result* noun, as it is for `Configure the <application: concurrency>`.
        let repository = result.base

        guard InMemoryRepositoryStorage.isRepositoryName(repository) else {
            throw ActionError.invalidInput(
                "Declare expects a repository: '\(repository)' is not one "
                + "(a repository's name ends in -repository)",
                received: repository)
        }

        // `_expression_` as well as `_with_`, because the two modes put the
        // object-slot map in different places. `Declare the <x> with { … }`
        // parses as `with the <_expression_>`: the interpreter binds the
        // evaluated map to both names, compiled code binds only
        // `_expression_`. Reading both is a two-word fix here; teaching
        // codegen to bind `_with_` for this shape is not — it would set
        // `_with_` for *every* statement of this shape, and `Store` uses the
        // presence of `_with_` to mean "the payload is the value" (GitLab
        // #515). Inside a `for each` body, where the compiled path does not
        // emit the per-statement transient sweep, a preceding
        // `Create the <r> with { … }` then leaks into the following
        // `Store the <r> into the <repo>` — which is how MedallionPipeline
        // went from six bronze rows to one.
        let properties = context.resolveAny("_with_")
            ?? context.resolveAny("_expression_")
            ?? context.resolveAny("_literal_")
        guard let fields = properties as? [String: any Sendable] else {
            throw ActionError.missingRequiredField(
                field: "with { scope: application | session | connection }",
                action: "Declare the <\(repository)>")
        }

        guard let rawScope = fields["scope"] else {
            let given = fields.keys.sorted().joined(separator: ", ")
            throw ActionError.invalidInput(
                "Declare the <\(repository)>: the required property is 'scope' "
                + "(\(RepositoryScope.allNames))",
                received: given.isEmpty ? "{}" : given)
        }

        let scopeText = rawScope as? String ?? String(describing: rawScope)
        guard let scope = RepositoryScope.parse(scopeText) else {
            throw ActionError.invalidInput(
                RepositoryScopeError.unknownScope(repository: repository,
                                                  raw: scopeText).description,
                received: scopeText)
        }

        // Two declarations that disagree mean one of them is wrong, and picking
        // either silently would make the wrong one look correct.
        if case .failure(let error) = RepositoryScopeRegistry.shared.declare(repository, scope: scope) {
            throw ActionError.invalidInput(error.description, received: scope.rawValue)
        }

        let record: [String: any Sendable] = [
            "repository": repository,
            "scope": scope.rawValue
        ]
        context.bind(result.base, value: record, allowRebind: true)
        return record
    }
}
