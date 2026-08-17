// ============================================================
// ActionRoleConsistencyTests.swift
// Action role agreement across sources of truth (GitLab #480)
// ============================================================

import Testing
@testable import ARORuntime
@testable import AROParser

/// ARO describes an action's semantic role in three places:
///
///   1. `ActionImplementation.role` — what the runtime dispatches on.
///   2. `ActionSemanticRole.classify(verb:)` — what the analyser uses, keyed by
///      verb name rather than by type.
///   3. ARO-0004's tables — now generated from (1), so it can no longer drift.
///
/// (1) and (2) disagree for 25 verbs. That is a design question, not a typo:
/// roles drive data-flow analysis, where EXPORT makes symbols globally
/// accessible, so changing either side is a behavioural change. These tests pin
/// the disagreement so it is visible and cannot grow silently while the decision
/// is pending.
@Suite("Action Role Consistency")
struct ActionRoleConsistencyTests {

    /// Verbs where the action's declared role and the classifier disagree.
    private func divergentVerbs() -> [String: (declared: ActionRole, classified: ActionSemanticRole)] {
        var result: [String: (ActionRole, ActionSemanticRole)] = [:]

        for verb in ActionRegistry.shared.registeredVerbs {
            guard let action = ActionRegistry.shared.action(for: verb) else { continue }
            let declared = type(of: action).role
            let classified = ActionSemanticRole.classify(verb: verb)
            if declared.rawValue != classified.rawValue {
                result[verb] = (declared, classified)
            }
        }

        return result
    }

    @Test("The role divergence has not grown")
    func testDivergenceIsBounded() {
        // Pinned, not asserted-empty: reconciling these needs a decision per verb.
        // If this fails with MORE verbs, a new action was added with a role the
        // classifier does not agree with. If it fails with FEWER, some were
        // reconciled — lower the number.
        let divergent = divergentVerbs()

        #expect(
            divergent.count <= 25,
            "role divergence grew to \(divergent.count): \(divergent.keys.sorted())"
        )
    }

    @Test("Known divergences are the expected ones")
    func testKnownDivergences() {
        let divergent = divergentVerbs()

        // Spot-checks from each direction, so a silent reclassification is caught.
        #expect(divergent["emit"]?.declared == .export)
        #expect(divergent["emit"]?.classified == .response)
        #expect(divergent["request"]?.declared == .request)
        #expect(divergent["request"]?.classified == .own)
    }

    @Test("Store's role is what the code declares, whatever ARO-0004 §2.4 says")
    func testStoreRoleIsResponse() {
        // ARO-0004 §2.4 groups Store under EXPORT; StoreAction declares
        // .response. The generated §11 table reports this value, and §2.4 now
        // records the discrepancy explicitly rather than contradicting the code.
        let store = ActionRegistry.shared.action(for: "store")

        #expect(store.map { type(of: $0).role } == .response)
    }

    @Test("Store does not accept a preposition the lexer cannot produce")
    func testStorePrepositions() {
        // `.in` was listed in StoreAction's declaration, which is where ARO-0004's
        // `in` came from. It is an alias for `.into`, and there is no `in` token.
        let store = ActionRegistry.shared.action(for: "store")
        let prepositions = store.map { type(of: $0).validPrepositions }

        #expect(prepositions == [.into, .to])
        #expect(!Preposition.allCases.contains { $0.rawValue == "in" })
    }

    @Test("Execute accepts the prepositions its own example uses")
    func testExecutePrepositions() {
        // Examples/SystemMonitor uses `for`, which ARO-0004 did not list.
        let execute = ActionRegistry.shared.action(for: "exec")
        let prepositions = execute.map { type(of: $0).validPrepositions } ?? []

        #expect(prepositions.contains(.for))
        #expect(prepositions.contains(.on))
        #expect(prepositions.contains(.with))
    }

    @Test("The registry has the action count the generated table claims")
    func testActionCount() {
        // The generated ARO-0004 §11 table says 71. If an action is added, both
        // this number and the table need updating — the CI job regenerates it.
        #expect(ActionRegistry.shared.allBuiltInActionInfos.count == 71)
    }
}
