// ============================================================
// VerbOverloadResolutionTests.swift
// ARO Runtime - two actions, one verb (GitLab #562)
// ============================================================
//
// `DeleteAction` claims the verb `clear` and its repository path documents the
// spelling: `Clear the <all> from the <message-repository>.` But
// `TerminalActions.ClearAction` claims `clear` too, and registration was
// `actions[verb] = type` — last writer wins, silently. `TerminalActionsModule`
// is registered after the pipeline module, so every `Clear` reached the
// terminal action and the repository form failed at run time with
// "Cannot clear the all from the m-repository."
//
// The two were never genuinely ambiguous: `ClearAction` accepts only `for`,
// `DeleteAction` accepts `from` as well. Resolution now reads the
// `validPrepositions` each action already declares.

import Testing
import Foundation
import AROParser
@testable import ARORuntime

@Suite("Verb overload resolution (GitLab #562)", .serialized)
struct VerbOverloadResolutionTests {

    // MARK: - Both spellings reach their own action

    @Test("`Clear … from` reaches the repository action")
    func clearFromReachesDelete() async throws {
        let context = RuntimeContext(featureSetName: "Test")
        let span = SourceSpan(at: SourceLocation())
        let storage = InMemoryRepositoryStorage.shared
        await storage.store(
            value: ["id": 1] as [String: any Sendable],
            in: "overload562-repository",
            businessActivity: "test"
        )

        _ = try await ActionRegistry.shared.execute(
            verb: "Clear",
            result: ResultDescriptor(base: "all", specifiers: [], span: span),
            object: ObjectDescriptor(
                preposition: .from, base: "overload562-repository", specifiers: [], span: span),
            context: context
        )

        let remaining = await storage.retrieve(
            from: "overload562-repository", businessActivity: "test")
        #expect(remaining.isEmpty, "the repository should have been emptied")
    }

    @Test("`Clear … for` still reaches the terminal action")
    func clearForReachesTerminal() async throws {
        let context = RuntimeContext(featureSetName: "Test")
        let span = SourceSpan(at: SourceLocation())

        let value = try await ActionRegistry.shared.execute(
            verb: "Clear",
            result: ResultDescriptor(base: "screen", specifiers: [], span: span),
            object: ObjectDescriptor(
                preposition: .for, base: "terminal", specifiers: [], span: span),
            context: context
        )

        #expect(value is ClearResult, "expected the terminal action, got \(type(of: value))")
    }

    @Test("`Delete … from` is unaffected — it was always the working spelling")
    func deleteStillWorks() async throws {
        let context = RuntimeContext(featureSetName: "Test")
        let span = SourceSpan(at: SourceLocation())
        let storage = InMemoryRepositoryStorage.shared
        await storage.store(
            value: ["id": 2] as [String: any Sendable],
            in: "overload562b-repository",
            businessActivity: "test"
        )

        _ = try await ActionRegistry.shared.execute(
            verb: "Delete",
            result: ResultDescriptor(base: "all", specifiers: [], span: span),
            object: ObjectDescriptor(
                preposition: .from, base: "overload562b-repository", specifiers: [], span: span),
            context: context
        )

        let remaining = await storage.retrieve(
            from: "overload562b-repository", businessActivity: "test")
        #expect(remaining.isEmpty)
    }

    // MARK: - The declarations that make it decidable

    @Test("The two claimants of `clear` differ in the prepositions they accept")
    func claimantsAreDistinguishable() {
        #expect(DeleteAction.verbs.contains("clear"))
        #expect(ClearAction.verbs.contains("clear"))
        // ClearAction is terminal-only; Delete carries `from`, which is what
        // makes the repository spelling decidable.
        #expect(ClearAction.validPrepositions == [.for])
        #expect(DeleteAction.validPrepositions.contains(.from))
        #expect(!ClearAction.validPrepositions.contains(.from))
    }

    // MARK: - No built-in action is shadowed out of existence

    @Test("No built-in verb has a claimant that nothing can reach")
    func noBuiltInIsUnreachable() {
        // The shape that hid this bug: a claimant every one of whose
        // prepositions is also claimed by a *later* registration is
        // unreachable, because resolution prefers the latest fitting one. This
        // asserts the built-in set has none, which is what #562 violated.
        var claimants: [String: [any ActionImplementation.Type]] = [:]
        for module in ActionRegistry.builtInModules {
            for actionType in module {
                for verb in actionType.verbs {
                    let key = verb.lowercased()
                    let seen = claimants[key]?.contains {
                        String(describing: $0) == String(describing: actionType)
                    } ?? false
                    if !seen { claimants[key, default: []].append(actionType) }
                }
            }
        }

        var unreachable: [String] = []
        for (verb, list) in claimants where list.count > 1 {
            for (index, claimant) in list.enumerated() {
                let later = list.dropFirst(index + 1)
                guard !later.isEmpty else { continue }
                let covered = later.reduce(into: Set<Preposition>()) {
                    $0.formUnion($1.validPrepositions)
                }
                if claimant.validPrepositions.isSubset(of: covered) {
                    unreachable.append("\(verb) on \(claimant)")
                }
            }
        }

        #expect(unreachable.isEmpty, "unreachable built-in actions: \(unreachable.sorted())")
    }
}
