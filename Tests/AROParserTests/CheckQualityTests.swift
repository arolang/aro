// ============================================================
// CheckQualityTests.swift
// AROParserTests — what `aro check` sees, and what it says
// GitLab #660, #675, #823, #844, #845
// ============================================================
//
// Five bugs about the checker's own credibility. It did not look inside
// half the language's block constructs, it accepted verbs that name no
// action, it recognised its own diagnostics by matching their prose, and
// roughly nine warnings in ten on the example set were false — which is the
// one that makes the other four not matter, because nobody reads a list
// that is mostly wrong.

import Testing
import Foundation
@testable import AROParser

@Suite("aro check quality (#660, #675, #823, #844, #845)")
struct CheckQualityTests {

    private func diagnostics(for source: String,
                             pluginActionsPossible: Bool = false) -> [Diagnostic] {
        Compiler().compile(source, pluginActionsPossible: pluginActionsPossible).diagnostics
    }

    private func errors(in source: String) -> [String] {
        diagnostics(for: source).filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(in source: String) -> [String] {
        diagnostics(for: source).filter { $0.severity == .warning }.map(\.message)
    }

    // MARK: - #660, the walk reaches every block

    @Test("An unknown qualifier is found inside while, range and when bodies")
    func theWalkReachesEveryBlock() {
        // Three private copies of the walk disagreed on coverage and none
        // descended into `when { }` or a pipeline, so the promise that "a
        // green check means the qualifier exists" held only at the top level
        // of a feature set.
        let source = """
        (Application-Start: Walk) {
            Create the <n> with 1.
            while <n> < 2 {
                Compute the <a: nosuchqualifier> from <n>.
            }
            for <i> from 1 to 2 {
                Compute the <b: alsonotone> from <i>.
            }
            when <n> = 1 {
                Compute the <c: neitheristhis> from <n>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let found = errors(in: source)
        #expect(found.contains { $0.contains("nosuchqualifier") })
        #expect(found.contains { $0.contains("alsonotone") })
        #expect(found.contains { $0.contains("neitheristhis") })
    }

    // MARK: - #844, a verb that names no action

    /// One statement, in the smallest feature set that holds it.
    private func inAFeatureSet(_ statement: String) -> String {
        """
        (Application-Start: V) {
            \(statement)
            Return an <OK: status> for the <startup>.
        }
        """
    }

    @Test("A verb that belongs to no action is an error")
    func unknownVerbIsRejected() {
        let found = errors(in: inAFeatureSet("Frobnicate the <x> from the <y>."))
        #expect(found.contains { $0.contains("'Frobnicate' is not a verb of any action") })
    }

    @Test("A misspelt verb names the one it meant")
    func misspeltVerbIsNamed() {
        let hints = diagnostics(
            for: inAFeatureSet("Retreive the <u> from the <user-repository>.")
        ).flatMap(\.hints)
        #expect(hints.contains { $0.contains("Retrieve") })
    }

    @Test("A dotted verb is accepted: it is a plugin or an ARO-0081 action")
    func dottedVerbsAreAccepted() {
        let found = errors(in: inAFeatureSet("Markdown.ToHTML the <html> from the <text>."))
        #expect(!found.contains { $0.contains("is not a verb of any action") })
    }

    @Test("An application with plugins has an open verb namespace")
    func pluginApplicationsAreNotSecondGuessed() {
        // A plugin's action names come from `aro_plugin_info()` at load time,
        // not from `plugin.yaml`, so `Greet` and `ParseCSV` cannot be told
        // from a typo without loading the plugin — and calling them mistakes
        // breaks every plugin example.
        let found = diagnostics(for: inAFeatureSet("Greet the <hello> from the <name>."),
                                pluginActionsPossible: true)
            .filter { $0.severity == .error }
        #expect(!found.contains { $0.message.contains("is not a verb of any action") })
    }

    // MARK: - #675, diagnostics recognised by code

    @Test("The two diagnostics the snippet path filters carry codes")
    func filterableDiagnosticsCarryCodes() {
        // They were matched by `message.hasPrefix("External dependency")` and
        // `message.contains("is defined but never used")`. Both had been
        // reworded before, and a filter that stops matching does not fail —
        // it silently stops filtering.
        let unused = diagnostics(for: """
        (Application-Start: U) {
            Create the <orphan> with 1.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(unused.contains { $0.code == .unusedVariable })

        let unpublished = diagnostics(for: """
        (Application-Start: D) {
            Require the <settings> from the <ConfigLoader>.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(unpublished.contains { $0.code == .unpublishedDependency })
    }

    // MARK: - #823, the warnings that were wrong

    @Test("An ARO-0015 test feature set is not asked for a Return")
    func testFeatureSetsEndWithThen() {
        // ARO-0015 §2.3: `Then` is their terminator, and every worked example
        // in the proposal ends that way.
        let found = warnings(in: """
        (length-of-hello: String Utils Test) {
            Given the <text> with "hello".
            When the <len> from the <get-length>.
            Then the <len> with 5.
        }
        """)
        #expect(!found.contains { $0.contains("has no Return") })
    }

    @Test("A shutdown handler is not asked for a Return")
    func applicationEndIsExempt() {
        // The guard for this existed and tested the wrong field: in
        // `(Application-End: Success)` the *name* is `Application-End` and
        // the activity is `Success`, so it never fired.
        let found = warnings(in: """
        (Application-End: Success) {
            Log "bye" to the <console>.
        }
        """)
        #expect(!found.contains { $0.contains("has no Return") })
    }

    @Test("An ARO-0015 test's own bindings are not called unused")
    func givenAndThenAreReadsNotWrites() {
        let found = warnings(in: """
        (uppercase-simple: String Utils Test) {
            Given the <text> with "hello".
            When the <upper> from the <make-uppercase>.
            Then the <upper> with "HELLO".
        }
        """)
        #expect(!found.contains { $0.contains("never used") })
        // `make-uppercase` names the feature set under test, not a variable.
        #expect(!found.contains { $0.contains("used before definition") })
    }

    @Test("A Call names a service, and an Exec's 'for' slot names a label")
    func serviceAndLabelSlotsAreNotVariables() {
        let call = warnings(in: """
        (Application-Start: C) {
            Call the <rows> from the <sqlite: execute> with { sql: "select 1" }.
            Log <rows> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(!call.contains { $0.contains("'sqlite' used before definition") })

        let exec = warnings(in: """
        (Application-Start: E) {
            Create the <command> with "uptime".
            Execute the <result> for the <listing> with <command>.
            Log <result> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(!exec.contains { $0.contains("'listing' used before definition") })
    }

    @Test("Store's qualifier-as-name form binds its base")
    func storeWithASpecifierDefinesTheBase() {
        // The runtime binds `stored-user` to the stored record, id and all —
        // that is the reason to write it this way. The analyzer read the
        // base instead, so the next line reported it unpublished.
        let found = warnings(in: """
        (createUser: User API) {
            Create the <user> with { name: "Ada" }.
            Store the <stored-user: user> into the <user-repository>.
            Return a <Created: status> with <stored-user>.
        }
        """)
        #expect(!found.contains { $0.contains("stored-user") })
    }

    @Test("An operand passed through 'against' or 'to' is a read")
    func secondaryClauseOperandsCount() {
        // `RangeModifiers` has carried all three clauses since GitLab #469;
        // only `with` was walked, so `Compare … against <actual>` reported
        // `actual` unused.
        let found = warnings(in: """
        (Application-Start: R) {
            Create the <expected> with 10.
            Create the <actual> with 10.
            Compare the <same> from the <expected> against the <actual>.
            Log <same> to the <console>.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(!found.contains { $0.contains("'actual' is defined but never used") })
    }

    @Test("Accept's transition and Sleep's handle are not called unused")
    func confirmationHandlesAreExempt() {
        let found = warnings(in: """
        (Application-Start: A) {
            Create the <order> with { status: "draft" }.
            Accept the <transition: draft_to_placed> on <order: status>.
            Sleep the <wait1> for 1 seconds.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(!found.contains { $0.contains("'transition'") })
        #expect(!found.contains { $0.contains("'wait1'") })
    }

    @Test("A genuine unused binding is still reported")
    func theRealFindingSurvives() {
        // The point of removing the noise is that this stays visible.
        let found = warnings(in: """
        (Application-Start: G) {
            Create the <orphan> with 1.
            Return an <OK: status> for the <startup>.
        }
        """)
        #expect(found.contains { $0.contains("'orphan' is defined but never used") })
    }

    // MARK: - #845, snippets that documentation actually contains

    @Test("A comment before a feature set does not turn it into a statement")
    func leadingCommentsAreSkipped() {
        #expect(CheckSnippetShape.skippingLeadingComments("""
        (* hi *)
        (createUser: User API) {
        """).hasPrefix("(createUser"))

        #expect(CheckSnippetShape.skippingLeadingComments("""
        (* one *)
        (* two *)

        (A: X) {
        """).hasPrefix("(A: X)"))
    }

    @Test("An unterminated comment is left for the parser to report")
    func unterminatedCommentIsNotGuessedAt() {
        let source = "(* never closed\n(A: X) {"
        #expect(CheckSnippetShape.skippingLeadingComments(source).hasPrefix("(* never"))
    }
}
