// ============================================================
// ActionVerbCatalogParityTests.swift
// ARORuntimeTests — the verb catalog mirrors the registry (GitLab #844)
// ============================================================
//
// `aro check` now rejects a statement whose verb belongs to no action, which
// it can only do from a list it holds itself: AROParser cannot import
// ARORuntime, because the check path deliberately never loads the runtime.
//
// So `ActionVerbCatalog` is a mirror, and a mirror needs something watching
// it. Register an action with a new verb and this test fails until the verb
// is in the catalog — the same arrangement that holds `ActionRoleCatalog` and
// `ComputeQualifierCatalog` to their runtime counterparts.
//
// The failure it prevents is the worse direction: a verb the runtime knows
// and the catalog does not is a *correct* program the checker rejects.

import XCTest
import AROParser
@testable import ARORuntime

final class ActionVerbCatalogParityTests: XCTestCase {

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

    private func registeredVerbs() -> Set<String> {
        var out: Set<String> = []
        for module in builtInModules {
            for type in module {
                for verb in type.verbs { out.insert(verb.lowercased()) }
            }
        }
        return out
    }

    func testEveryRegisteredVerbIsInTheCatalog() {
        let missing = registeredVerbs().subtracting(ActionVerbCatalog.allVerbs).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            """
            \(missing.count) verb(s) the runtime registers are missing from \
            ActionVerbCatalog, so `aro check` rejects correct programs that \
            use them: \(missing.joined(separator: ", ")). \
            Add them to Sources/AROParser/ActionVerbCatalog.swift.
            """
        )
    }

    func testTheCatalogInventsNothing() {
        let extra = ActionVerbCatalog.allVerbs.subtracting(registeredVerbs()).sorted()
        XCTAssertTrue(
            extra.isEmpty,
            """
            \(extra.count) verb(s) in ActionVerbCatalog name no registered \
            action, so `aro check` accepts a statement that fails at run \
            time: \(extra.joined(separator: ", ")).
            """
        )
    }

    func testADottedNameIsAlwaysAccepted() {
        // A plugin action or an ARO-0081 call. Neither is resolvable at check
        // time, and rejecting them would break every plugin example.
        XCTAssertTrue(ActionVerbCatalog.isKnownVerb("Markdown.ToHTML"))
        XCTAssertTrue(ActionVerbCatalog.isKnownVerb("Application.DoubleValue"))
    }

    func testAMisspellingNamesItsNeighbour() {
        XCTAssertEqual(ActionVerbCatalog.closestVerb(to: "Retreive"), "retrieve")
        XCTAssertEqual(ActionVerbCatalog.closestVerb(to: "Comptue"), "compute")
        // Nothing within two edits: better to say nothing than to guess.
        XCTAssertNil(ActionVerbCatalog.closestVerb(to: "Frobnicate"))
    }
}
