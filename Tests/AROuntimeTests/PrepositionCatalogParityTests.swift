// ============================================================
// PrepositionCatalogParityTests.swift
// Guards AROParser.PrepositionCatalog against the runtime (GitLab #479)
// ============================================================

import Testing
@testable import ARORuntime
@testable import AROParser

/// `PrepositionCatalog` lives in AROParser because the analyser cannot import
/// ARORuntime — the dependency runs the other way. That makes it a mirror, and
/// mirrors drift: the same drift is exactly what made `DataFlowAnalyzer`'s
/// system-object list wrong (#478) and what ARO-0004's action table suffers
/// from (#480).
///
/// These tests close the loop from the runtime side, where both the registry and
/// the catalog are visible. They are the reason the generated table can be
/// trusted.
@Suite("Preposition Catalog Parity")
struct PrepositionCatalogParityTests {

    @Test("Every registered verb has a catalog entry")
    func testEveryRegisteredVerbIsCatalogued() {
        let missing = ActionRegistry.shared.registeredVerbs
            .filter { PrepositionCatalog.prepositions(forVerb: $0) == nil }
            .sorted()

        #expect(
            missing.isEmpty,
            "PrepositionCatalog is missing entries for: \(missing)"
        )
    }

    @Test("Catalog entries match the registered action's validPrepositions")
    func testCatalogMatchesRegistry() {
        var mismatches: [String] = []

        for verb in ActionRegistry.shared.registeredVerbs.sorted() {
            guard let catalogued = PrepositionCatalog.prepositions(forVerb: verb) else { continue }
            guard let action = ActionRegistry.shared.action(for: verb) else { continue }

            // The registry resolves a verb to exactly one action, so the
            // catalogued set must at least contain that action's set. It may be
            // larger for the three verbs two actions claim, where the catalog
            // holds the union deliberately.
            let actual = type(of: action).validPrepositions
            if !catalogued.isSuperset(of: actual) {
                mismatches.append(
                    "\(verb): catalog \(catalogued.map(\.rawValue).sorted()) does not cover runtime \(actual.map(\.rawValue).sorted())"
                )
            }
        }

        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    @Test("The catalog does not invent prepositions the runtime rejects")
    func testCatalogIsNotOverlyPermissive() {
        // Union entries are expected for verbs claimed by more than one action.
        // Everything else must match exactly, otherwise the checker would pass
        // code that fails at run time — the failure mode this issue is about.
        let knownUnionVerbs: Set<String> = ["parse", "map", "clear"]
        var overlyPermissive: [String] = []

        for verb in ActionRegistry.shared.registeredVerbs.sorted() {
            guard !knownUnionVerbs.contains(verb.lowercased()) else { continue }
            guard let catalogued = PrepositionCatalog.prepositions(forVerb: verb),
                  let action = ActionRegistry.shared.action(for: verb) else { continue }

            let actual = type(of: action).validPrepositions
            if catalogued != actual {
                overlyPermissive.append(
                    "\(verb): catalog \(catalogued.map(\.rawValue).sorted()) != runtime \(actual.map(\.rawValue).sorted())"
                )
            }
        }

        #expect(overlyPermissive.isEmpty, "\(overlyPermissive)")
    }

    @Test("Store's phantom 'in' preposition is not in the catalog")
    func testStoreInAliasIsResolved() {
        // StoreAction declares [.into, .to, .in]. `.in` is an alias for `.into`,
        // and the lexer has no `in` token, so `Store … in the <repo>.` does not
        // parse at all — see #480.
        let store = PrepositionCatalog.prepositions(forVerb: "store")

        #expect(store == [.into, .to])
        #expect(Preposition.in == .into)
    }
}
