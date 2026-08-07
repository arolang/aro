// ============================================================
// PrepositionValidationTests.swift
// AROParser - Preposition validation at check time (GitLab #479)
// ============================================================

import Testing
@testable import AROParser

@Suite("Preposition Validation")
struct PrepositionValidationTests {

    /// Preposition diagnostics, regardless of severity.
    ///
    /// Reported as warnings rather than errors — see the note in
    /// `CodeQualityValidator.validatePrepositions`: some statements never
    /// dispatch their action, so spellings the runtime tolerates today would
    /// otherwise become hard failures.
    private func prepositionErrors(_ source: String) -> [String] {
        Compiler.compile(source).diagnostics
            .map(\.message)
            .filter { $0.contains("does not accept the preposition") }
    }

    // MARK: - Invalid prepositions are errors

    @Test("Exec with 'from' is an error")
    func testExecFromIsError() {
        // The case from the issue: silent before, then a runtime failure whose
        // message never mentioned the preposition.
        let errors = prepositionErrors("""
        (Application-Start: T) {
            Exec the <r> from the <command: "echo hi">.
            Log <r> to the <console>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(errors.count == 1)
        #expect(errors[0].contains("Exec"))
        #expect(errors[0].contains("from"))
    }

    @Test("Close with 'for' is an error")
    func testCloseForIsError() {
        // Found in Examples/UserService by this very check: CloseAction accepts
        // only with/from, and ARO-0004 agrees.
        let errors = prepositionErrors("""
        (Application-Start: T) {
            Close the <connections> for the <application>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(errors.count == 1)
    }

    @Test("The diagnostic is a warning, not an error")
    func testSeverityIsWarning() {
        let result = Compiler.compile("""
        (Application-Start: T) {
            Exec the <r> from the <command: "true">.
            Return an <OK: status> for the <t>.
        }
        """)
        let prepositionDiagnostics = result.diagnostics.filter {
            $0.message.contains("does not accept the preposition")
        }

        #expect(prepositionDiagnostics.count == 1)
        #expect(prepositionDiagnostics.allSatisfy { $0.severity == .warning })
        // Must not fail the build: `Make … with` works today via the executor's
        // expression fast path, and erroring would break it.
        #expect(!result.hasErrors)
    }

    @Test("The diagnostic names the accepted prepositions")
    func testErrorIncludesHint() {
        let result = Compiler.compile("""
        (Application-Start: T) {
            Exec the <r> from the <command: "true">.
            Return an <OK: status> for the <t>.
        }
        """)
        let hints = result.diagnostics.flatMap(\.hints)

        #expect(hints.contains { $0.contains("for") && $0.contains("on") && $0.contains("with") })
        #expect(hints.contains { $0.contains("Did you mean") })
    }

    // MARK: - Valid prepositions are accepted

    @Test("Every documented example spelling is accepted")
    func testValidSpellingsAccepted() {
        let sources = [
            #"Exec the <r> for the <command: "true">."#,
            "Extract the <d> from the <request: body>.",
            "Compute the <n: length> from <s>.",
            "Compare the <a> against the <b>.",
            "Store the <u> into the <user-repository>.",
            "Log <x> to the <console>.",
            "Return an <OK: status> for the <t>.",
            "Write the <c> to the <file: p>.",
            "Transform the <o> from the <i>.",
            "Filter the <big> from the <items>.",
        ]
        for source in sources {
            let errors = prepositionErrors("""
            (Application-Start: T) {
                Create the <s> with "abcd".
                Create the <p> with "./x".
                Create the <items> with [1, 2].
                Create the <i> with 1.
                Create the <a> with 1.
                Create the <b> with 2.
                Create the <u> with 3.
                Create the <x> with 4.
                Create the <c> with "y".
                \(source)
                Return an <OK: status> for the <done>.
            }
            """)
            #expect(errors.isEmpty, "\(source) -> \(errors)")
        }
    }

    @Test("Store accepts 'to' as well as 'into'")
    func testStoreAcceptsBoth() {
        for preposition in ["into", "to"] {
            let errors = prepositionErrors("""
            (Application-Start: T) {
                Create the <u> with 1.
                Store the <u> \(preposition) the <user-repository>.
                Return an <OK: status> for the <t>.
            }
            """)
            #expect(errors.isEmpty, "Store … \(preposition) rejected")
        }
    }

    // MARK: - Unknown verbs are not our business

    @Test("A user-defined action is not preposition-checked")
    func testUserDefinedActionSkipped() {
        // Application.<Name> prepositions are only known at run time.
        let errors = prepositionErrors("""
        (Double: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Return an <OK: status> with <v>.
        }
        (Application-Start: T) {
            Application.Double the <r> from 5.
            Log <r> to the <console>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(errors.isEmpty)
    }

    @Test("An unrecognised verb produces no preposition error")
    func testUnknownVerbSkipped() {
        // Unknown actions are diagnosed elsewhere; a preposition error would be
        // a confusing second report for the same mistake.
        let errors = prepositionErrors("""
        (Application-Start: T) {
            Frobnicate the <r> from the <thing>.
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(errors.isEmpty)
    }

    // MARK: - Nested statements

    @Test("Statements inside a for-each body are checked")
    func testInsideLoopBody() {
        let errors = prepositionErrors("""
        (Application-Start: T) {
            Create the <items> with [1, 2].
            for each <item> in <items> {
                Exec the <r> from the <command: "true">.
            }
            Return an <OK: status> for the <t>.
        }
        """)

        #expect(errors.count == 1)
    }
}

// MARK: - Catalog

@Suite("Preposition Catalog")
struct PrepositionCatalogTests {

    @Test("Covers every implemented verb in ActionCatalog")
    func testCoversActionCatalog() {
        // `ActionCatalog` exists to declare LLVM external symbols, and it lists
        // three verbs that no action actually implements:
        //
        //   route, watch  — targets of ActionRunner's canonicalisation
        //                   (forward -> route, monitor/observe -> watch), but no
        //                   RouteAction or WatchAction exists, so writing them
        //                   fails with unknownAction at run time.
        //   concat        — documented as a Merge verb in ARO-0004, but
        //                   MergeAction.verbs is only ["merge", "combine"].
        //
        // Pinned here so the gap is visible and cannot widen silently. Remove a
        // name from this set when its action lands.
        let knownUnimplemented: Set<String> = ["route", "watch", "concat"]

        let missing = ActionCatalog.allActionVerbs
            .filter { !knownUnimplemented.contains($0) }
            .filter { PrepositionCatalog.prepositions(forVerb: $0) == nil }

        #expect(missing.isEmpty, "no preposition entry for: \(missing.sorted())")
    }

    @Test("The unimplemented-verb gap is exactly the three known names")
    func testUnimplementedVerbGapIsStable() {
        // Fails if a new orphan appears in ActionCatalog, or if one of the three
        // gets implemented (in which case remove it from both sets).
        let orphans = ActionCatalog.allActionVerbs
            .filter { PrepositionCatalog.prepositions(forVerb: $0) == nil }
            .sorted()

        #expect(orphans == ["concat", "route", "watch"])
    }

    @Test("Every entry has at least one preposition")
    func testNoEmptyEntries() {
        for (verb, preps) in PrepositionCatalog.prepositionsByVerb {
            #expect(!preps.isEmpty, "\(verb) has an empty preposition set")
        }
    }

    @Test("Lookup is case-insensitive")
    func testCaseInsensitive() {
        #expect(PrepositionCatalog.prepositions(forVerb: "Exec") != nil)
        #expect(PrepositionCatalog.prepositions(forVerb: "EXEC") != nil)
    }

    @Test("Unknown verbs validate as true, never as invalid")
    func testUnknownVerbIsValid() {
        #expect(PrepositionCatalog.isValid(preposition: .from, forVerb: "not-an-action"))
        #expect(PrepositionCatalog.prepositions(forVerb: "not-an-action") == nil)
    }

    @Test("Multi-owner verbs hold the union of both actions' sets")
    func testMultiOwnerUnion() {
        // `map` is claimed by TransformAction (.from/.into/.to) and MapAction
        // (.from/.to). The registry resolves by registration order, which this
        // table cannot know, so the union is the safe answer.
        let map = PrepositionCatalog.prepositions(forVerb: "map")

        #expect(map?.contains(.from) == true)
        #expect(map?.contains(.to) == true)
        #expect(map?.contains(.into) == true)
    }

    @Test("Alias prepositions are resolved to their targets")
    func testAliasesResolved() {
        // StoreAction declares [.into, .to, .in], but `Preposition.in` is an
        // alias for `.into` (ServerActions.swift), and the lexer has no `in`
        // token at all — so the table must contain .into, not a phantom case.
        let store = PrepositionCatalog.prepositions(forVerb: "store")

        #expect(store == [.into, .to])
    }

    @Test("hintList is stable and sorted")
    func testHintListSorted() {
        #expect(PrepositionCatalog.hintList(forVerb: "exec") == "for, on, with")
    }
}
