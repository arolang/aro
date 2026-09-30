// ============================================================
// LanguageGapTests.swift
// AROParser — the gaps the books taught workarounds for (GitLab #830)
// ============================================================
//
// Five of the fifteen items in #830 are grammar or catalog gaps rather
// than design work, and each had a documented workaround standing in for
// it. A workaround in a book is a measurement: it says the language could
// not express the thing, and somebody wrote three paragraphs explaining
// how to go around it.
//
// So the tests here are paired. The positive case is the spelling that
// now works; the counter-case is the thing the workaround existed to
// avoid, still behaving the way it must.

import Testing
@testable import AROParser

@Suite("Language gaps the books taught workarounds for (#830)")
struct LanguageGapTests {

    private func compile(_ body: String) -> CompilationResult {
        Compiler().compile("""
        (Check: Demo) {
        \(body)
            Return an <OK: status> for the <check>.
        }
        """)
    }

    private func errors(_ body: String) -> [String] {
        compile(body).diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    private func warnings(_ body: String) -> [String] {
        compile(body).diagnostics.filter { $0.severity == .warning }.map(\.message)
    }

    // MARK: - Item 5: when / where operator parity

    @Test("`when … starts with` parses, where it used to need a regex")
    func whenStartsWith() {
        #expect(errors("""
                Compute the <path> from "/api/users".
                Log "api" to the <console> when <path> starts with "/api".
        """).isEmpty)
    }

    @Test("`when … ends with` parses")
    func whenEndsWith() {
        #expect(errors("""
                Compute the <name> from "main.aro".
                Log "aro" to the <console> when <name> ends with ".aro".
        """).isEmpty)
    }

    @Test("`when … not in` parses, matching where's operator set")
    func whenNotIn() {
        #expect(errors("""
                Create the <banned> with ["spam"].
                Compute the <tag> from "news".
                Log "ok" to the <console> when <tag> not in <banned>.
        """).isEmpty)
    }

    @Test("`where … starts with` / `ends with` parse")
    func whereAffixes() {
        #expect(errors("""
                Create the <files> with [{ name: "a.aro" }].
                Filter the <aro> from the <files> where <name> ends with ".aro".
                Filter the <a-files> from the <files> where <name> starts with "a".
        """).isEmpty)
    }

    /// The two words are not reserved. `<starts>` and `<ends>` are names
    /// somebody has already written, and taking them would be the
    /// regression GitLab #497 describes.
    @Test("`starts` and `ends` are still ordinary variable names")
    func affixWordsAreNotKeywords() {
        #expect(errors("""
                Compute the <starts> from 1.
                Compute the <ends> from 2.
                Compute the <total> from <starts> + <ends>.
        """).isEmpty)
    }

    /// `not` alone stays the unary negation. Only `not in` is infix.
    @Test("Bare `not` is still negation, not half an operator")
    func bareNotStillNegates() {
        #expect(errors("""
                Compute the <flag> from true.
                Log "off" to the <console> when not <flag>.
        """).isEmpty)
    }

    @Test("`starts` without `with` is not an operator")
    func startsWithoutWithIsNotAnOperator() {
        // `<a> starts` is two expressions with nothing joining them, and
        // the parser must say so rather than invent an operator.
        #expect(!errors("""
                Compute the <a> from "x".
                Log "n" to the <console> when <a> starts "x".
        """).isEmpty)
    }

    // MARK: - Item 14: Publish takes a guard

    @Test("`Publish as <x> <y> when …` parses and keeps the condition")
    func publishTakesAGuard() {
        let result = compile("""
                Compute the <score> from 90.
                Publish as <high> <score> when <score> > 50.
        """)
        #expect(result.diagnostics.filter { $0.severity == .error }.isEmpty)

        let publishes = result.program.featureSets.first?.statements
            .compactMap { $0 as? PublishStatement } ?? []
        #expect(publishes.count == 1)
        #expect(publishes.first?.statementGuard.isPresent == true)
    }

    @Test("An unguarded Publish still has no guard")
    func unguardedPublishHasNoGuard() {
        let result = compile("""
                Compute the <score> from 90.
                Publish as <high> <score>.
        """)
        let publishes = result.program.featureSets.first?.statements
            .compactMap { $0 as? PublishStatement } ?? []
        #expect(publishes.first?.statementGuard.isPresent == false)
    }

    @Test("A guarded Publish prints its guard back")
    func guardedPublishDescribesItself() {
        let result = compile("""
                Compute the <score> from 90.
                Publish as <high> <score> when <score> > 50.
        """)
        let publish = result.program.featureSets.first?.statements
            .compactMap { $0 as? PublishStatement }.first
        #expect(publish?.description.contains("when") == true)
    }

    // MARK: - Item 15: status names

    @Test("The four statuses the issue names now resolve")
    func theMissingStatusesResolve() {
        #expect(HTTPStatusCatalog.code(for: "Unprocessable") == 422)
        #expect(HTTPStatusCatalog.code(for: "TooManyRequests") == 429)
        #expect(HTTPStatusCatalog.code(for: "MethodNotAllowed") == 405)
        #expect(HTTPStatusCatalog.code(for: "Unavailable") == 503)
    }

    @Test("Spelling is not a distinction: case and separators normalise")
    func statusSpellingsNormalise() {
        for spelling in ["NoContent", "no-content", "no_content", "NO CONTENT", "nocontent"] {
            #expect(HTTPStatusCatalog.code(for: spelling) == 204, "failed on '\(spelling)'")
        }
    }

    @Test("Every canonical name round-trips through its own code")
    func canonicalNamesRoundTrip() {
        for (code, name) in HTTPStatusCatalog.canonicalName {
            #expect(HTTPStatusCatalog.code(for: name) == code,
                    "'\(name)' should resolve to \(code)")
        }
    }

    @Test("Every code a name maps to has a reason phrase")
    func everyCodeHasAReason() {
        for code in Set(HTTPStatusCatalog.byName.values) {
            #expect(HTTPStatusCatalog.reasonPhrase[code] != nil,
                    "\(code) has no reason phrase")
            #expect(HTTPStatusCatalog.canonicalName[code] != nil,
                    "\(code) has no canonical name")
        }
    }

    @Test("A misspelt status warns and names the one that was meant")
    func misspeltStatusWarns() {
        let result = Compiler().compile("""
        (Check: Demo) {
            Return a <NotFoudn: status> for the <check>.
        }
        """)
        let warning = result.diagnostics.first { $0.severity == .warning }
        #expect(warning?.message.contains("NotFoudn") == true)
        #expect(warning?.hints.contains { $0.contains("NotFound") } == true)
    }

    /// ARO-0002 §7 writes `Return a <PendingVerification: status>` and
    /// means it: a domain status that is a 200 on the wire. Warning about
    /// those would be the noise GitLab #823 is about.
    @Test("A domain status is left alone")
    func domainStatusIsNotWarnedAbout() {
        let result = Compiler().compile("""
        (Check: Demo) {
            Return a <PendingVerification: status> for the <check>.
        }
        """)
        #expect(!result.diagnostics.contains { $0.message.contains("PendingVerification") })
    }

    @Test("A status in the object slot is a field access, not a name")
    func statusInObjectSlotIsNotChecked() {
        let result = Compiler().compile("""
        (Check: Demo) {
            Create the <order> with { status: "open" }.
            Return an <OK: status> with <order: status>.
        }
        """)
        #expect(result.diagnostics.filter { $0.severity == .warning }.isEmpty)
    }

    @Test("A name nowhere near a real one is a domain status, not a typo")
    func distantNameIsNotGuessedAt() {
        #expect(HTTPStatusCatalog.closestMatch(to: "Teapot") == nil)
        #expect(HTTPStatusCatalog.closestMatch(to: "PendingVerification") == nil)
        #expect(HTTPStatusCatalog.closestMatch(to: "NotFoudn") == "NotFound")
        #expect(HTTPStatusCatalog.closestMatch(to: "Creatd") == "Created")
    }
}

// ============================================================
// `subset of` on both sides of the one operator set (GitLab #894)
// ============================================================
//
// The set diverged again, for exactly one operator: `when` accepted
// `subset of` from #864 and `where` never did. That is the shape #830 was
// filed about — a predicate you can guard a statement with but cannot filter
// a collection with — and `subset of` is most useful on the filtering side,
// since "which records have a role set covered by what the caller was
// granted" is a `Filter`, not a `when`.
//
// It has now drifted twice, so the last test here is a drift guard rather
// than another example: every operator in the shared table, asserted to parse
// in *both* grammars. A third divergence fails it by construction.

@Suite("`subset of` is in both operator sets (#894)")
struct SubsetOperatorParityTests {

    private func errors(_ body: String) -> [String] {
        Compiler().compile("""
        (Check: Demo) {
        \(body)
            Return an <OK: status> for the <check>.
        }
        """).diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    @Test("`where … subset of` parses")
    func whereSubsetOf() {
        #expect(errors("""
                Create the <teams> with [{ roles: ["read"] }].
                Create the <granted> with ["read", "write"].
                Filter the <ok> from the <teams> where <roles> subset of <granted>.
        """).isEmpty)
    }

    @Test("`when … subset of` still parses")
    func whenSubsetOf() {
        #expect(errors("""
                Create the <required> with ["read"].
                Create the <held> with ["read", "write"].
                Log "ok" to the <console> when <required> subset of <held>.
        """).isEmpty)
    }

    /// `of` is part of the operator and optional, in both grammars — one
    /// operator written in two places must not disagree about its own syntax.
    @Test("The `of` is optional on both sides")
    func ofIsOptionalOnBothSides() {
        #expect(errors("""
                Create the <rows> with [{ v: ["a"] }].
                Create the <all> with ["a", "b"].
                Filter the <ok> from the <rows> where <v> subset <all>.
                Log "ok" to the <console> when <all> subset <all>.
        """).isEmpty)
    }

    /// `<subset>` is a name people write, and making the word an operator
    /// everywhere would have taken it away.
    @Test("`subset` is still an ordinary name outside operator position")
    func subsetIsStillAName() {
        #expect(errors("""
                Create the <subset> with ["a"].
                Log <subset> to the <console>.
        """).isEmpty)
    }

    /// The drift guard. CLAUDE.md says `when` and `where` take the same
    /// operator set; this asserts it instead of repeating it. Adding an
    /// operator to one grammar and not the other fails here.
    @Test("Every shared operator parses in both `when` and `where`")
    func bothGrammarsAcceptTheSharedSet() {
        // (operator, right-hand side) — the left is always <v>.
        let operators: [(String, String)] = [
            ("is", "\"x\""),
            ("=", "\"x\""),
            ("!=", "\"x\""),
            (">", "1"),
            ("<", "1"),
            (">=", "1"),
            ("<=", "1"),
            ("contains", "\"x\""),
            ("matches", "\"^x\""),
            ("starts with", "\"x\""),
            ("ends with", "\"x\""),
            ("in", "<pool>"),
            ("not in", "<pool>"),
            ("before", "<other>"),
            ("after", "<other>"),
            ("subset of", "<pool>"),
        ]

        let preamble = """
                Create the <pool> with ["x"].
                Create the <other> with "2026-01-01".
                Create the <rows> with [{ v: "x" }].
        """

        for (op, rhs) in operators {
            let whereErrors = errors(preamble + """
            \n        Filter the <hit> from the <rows> where <v> \(op) \(rhs).
            """)
            #expect(whereErrors.isEmpty,
                    "`where … \(op)` did not parse: \(whereErrors)")

            let whenErrors = errors(preamble + """
            \n        Create the <v> with "x".
                    Log "ok" to the <console> when <v> \(op) \(rhs).
            """)
            #expect(whenErrors.isEmpty,
                    "`when … \(op)` did not parse: \(whenErrors)")
        }
    }
}
