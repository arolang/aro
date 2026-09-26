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
/// (1) and (2) used to disagree for 25 verbs, pinned here so the divergence
/// could not grow silently "while the decision is pending". GitLab #585 is that
/// decision: there is now one table, `ActionRoleCatalog`, mirroring the
/// registry, and these tests assert agreement instead of cataloguing the
/// disagreement.
///
/// The two runtime decisions that keyed on `semanticRole == .response` — the
/// side-effect re-run after the expression fast path, and the result binding —
/// now ask `ActionRoleCatalog.mustRunForEffect` instead. Those were never role
/// questions; using the role as a proxy is what made correcting `emit`
/// behaviour-changing rather than cosmetic.
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

    @Test("The declared role and the classifier agree for every registered verb")
    func testNoDivergence() {
        // Was `<= 25`, pinned while the decision was pending. It is now zero:
        // add an action whose role the catalog does not mirror and this fails.
        let divergent = divergentVerbs()

        let detail = divergent
            .map { "\($0.key) (declared \($0.value.declared), classified \($0.value.classified))" }
            .sorted().joined(separator: ", ")
        #expect(divergent.isEmpty, "roles disagree for \(divergent.count) verb(s): \(detail)")
    }

    @Test("The verbs that used to diverge now agree")
    func testFormerDivergencesAgree() {
        // Spot-checks from each direction, so a silent reclassification is
        // still caught — now by agreement rather than by disagreement.
        #expect(ActionSemanticRole.classify(verb: "emit") == .export)
        #expect(ActionSemanticRole.classify(verb: "request") == .request)
        #expect(ActionSemanticRole.classify(verb: "commit") == .export)
        #expect(ActionSemanticRole.classify(verb: "probe") == .request)
        #expect(ActionSemanticRole.classify(verb: "append") == .response)
    }

    @Test("The enumeration is not vacuous")
    func testEnumerationIsNotVacuous() {
        // A parity test over an empty set passes for the wrong reason.
        #expect(ActionRegistry.shared.registeredVerbs.count > 100)
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
        // The generated ARO-0004 §11 table says 75. If an action is added, both
        // this number and the table need updating — the CI job regenerates it.
        // 72 since Configure became an action of its own (GitLab #728);
        // 73 since Touch left MakeAction to be its own (GitLab #861);
        // 75 since Declare and Attach arrived with caller-scoped repositories
        // (ARO-0094, GitLab #885).
        #expect(ActionRegistry.shared.allBuiltInActionInfos.count == 75)
    }
}
