// ============================================================
// ActionRoleParityTests.swift
// ARORuntimeTests - one role taxonomy, held together (GitLab #585)
// ============================================================
//
// The semantic role was defined twice — `ActionSemanticRole.classify(verb:)`
// in AROParser and `ActionImplementation.role` on each action type — and the
// two disagreed on **25 of 136** registered verbs. Hover over `Emit` in SOLARO
// and it said "response"; `aro actions` said "export". Most of the rest
// differed because `classify` had no entry for the verb and fell through to
// `.own`, so it was never simply a stale copy.
//
// AROParser cannot import ARORuntime, so the table is mirrored in
// `ActionRoleCatalog` and this test is what keeps the mirror honest — the same
// arrangement `ComputeQualifierCatalog` and `ComputeAction.builtInQualifiers`
// already use. Add a verb to one and this fails until you add it to the other.

import XCTest
import AROParser
@testable import ARORuntime

final class ActionRoleParityTests: XCTestCase {

    /// Every built-in action type, in registration order.
    private var builtInModules: [[any ActionImplementation.Type]] {
        var modules: [[any ActionImplementation.Type]] = [
            RequestActionsModule.actions,
            OwnActionsModule.actions,
            ResponseActionsModule.actions,
            ServerActionsModule.actions,
            SocketActionsModule.actions,
            FileActionsModule.actions,
            DataPipelineActionsModule.actions,
            TestActionsModule.actions,
            TerminalActionsModule.actions,
            SystemActionsModule.actions,
        ]
        #if !os(Windows)
        modules.append(GitActionsModule.actions)
        #endif
        return modules
    }

    /// verb → the registry's role.
    private func registryRoles() -> [String: ActionRole] {
        var out: [String: ActionRole] = [:]
        for module in builtInModules {
            for type in module {
                for verb in type.verbs { out[verb.lowercased()] = type.role }
            }
        }
        return out
    }

    // MARK: - The parity that was missing

    func testEveryRegisteredVerbAgreesWithTheCatalog() {
        var mismatches: [String] = []
        for (verb, registryRole) in registryRoles() {
            let catalogRole = ActionSemanticRole.classify(verb: verb)
            if String(describing: registryRole) != String(describing: catalogRole) {
                mismatches.append("\(verb): registry=\(registryRole) catalog=\(catalogRole)")
            }
        }
        XCTAssertTrue(mismatches.isEmpty,
                      "roles disagree for \(mismatches.count) verb(s):\n" +
                      mismatches.sorted().joined(separator: "\n"))
    }

    func testTheCatalogHasNoVerbTheRegistryDoesNotKnow() {
        // A catalog entry for a verb nothing registers is dead weight that
        // would quietly drift; the registry is the source of truth in spirit.
        let registered = Set(registryRoles().keys)
        let extra = Set(ActionRoleCatalog.roles.keys).subtracting(registered)
        XCTAssertTrue(extra.isEmpty, "catalog knows verbs the registry does not: \(extra.sorted())")
    }

    func testTheProbeIsNotVacuous() {
        // If the enumeration broke, the parity test above would pass trivially.
        XCTAssertGreaterThan(registryRoles().count, 100)
    }

    // MARK: - The verb the issue names

    func testEmitIsExportOnBothSides() {
        XCTAssertEqual(String(describing: EmitAction.role), "export")
        XCTAssertEqual(String(describing: ActionSemanticRole.classify(verb: "Emit")), "export")
    }

    func testTheVerbsTheIssueListsAreNoLongerMisreported() {
        // A sample of the 25, across all four roles that were wrong.
        let expected: [String: String] = [
            "emit": "export", "commit": "export", "push": "export", "tag": "export",
            "clone": "request", "probe": "request", "stat": "request", "find": "request",
            "append": "response", "dispatch": "response", "fail": "response", "raise": "response",
        ]
        for (verb, role) in expected {
            XCTAssertEqual(String(describing: ActionSemanticRole.classify(verb: verb)), role,
                           "\(verb) still misreported")
        }
    }

    // MARK: - The runtime predicate is no longer the role

    func testMustRunForEffectCoversBothResponseAndExportVerbs() {
        // The executor's real question. An effect verb can be RESPONSE
        // (Return, Log) or EXPORT (Emit) — which is exactly why keying the
        // decision on the role was wrong.
        XCTAssertTrue(ActionRoleCatalog.mustRunForEffect("Return"))
        XCTAssertTrue(ActionRoleCatalog.mustRunForEffect("Log"))
        XCTAssertTrue(ActionRoleCatalog.mustRunForEffect("Emit"))
        XCTAssertTrue(ActionRoleCatalog.mustRunForEffect("Store"))

        XCTAssertFalse(ActionRoleCatalog.mustRunForEffect("Compute"))
        XCTAssertFalse(ActionRoleCatalog.mustRunForEffect("Retrieve"))
        XCTAssertFalse(ActionRoleCatalog.mustRunForEffect("Publish"))
    }

    func testEmitStillMustRunForItsEffectDespiteBeingExport() {
        // The regression this change had to avoid: correcting the role must not
        // stop an Emit running after the expression fast path, nor start it
        // binding a result. The issue calls today's behaviour "correct by
        // accident, from the wrong list" — it is now correct on purpose.
        XCTAssertEqual(String(describing: ActionSemanticRole.classify(verb: "emit")), "export")
        XCTAssertTrue(ActionRoleCatalog.mustRunForEffect("emit"))
    }

    func testEmitIsNotDeferrable() {
        // The other decision the old role guard covered. The allowlist already
        // excludes it, so the guard was belt-and-braces — but it must stay true.
        XCTAssertFalse(LazyActionPolicy.deferrable("emit"))
    }

    // MARK: - Unknown verbs

    func testAnUnknownVerbIsOwn() {
        // A plugin action the parser has not seen is internal-to-internal as
        // far as data flow goes, and the registry answers for it once loaded.
        XCTAssertEqual(String(describing: ActionSemanticRole.classify(verb: "NoSuchVerb")), "own")
    }

    func testClassificationIsCaseInsensitive() {
        for spelling in ["Emit", "emit", "EMIT"] {
            XCTAssertEqual(String(describing: ActionSemanticRole.classify(verb: spelling)), "export")
        }
    }
}
