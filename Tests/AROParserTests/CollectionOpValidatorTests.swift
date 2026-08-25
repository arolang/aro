// ============================================================
// CollectionOpValidatorTests.swift
// AROParser — collection ops rejected at check time (GitLab #465)
// ============================================================
//
// The four spellings from the issue. Each passed `aro check` with
// exit 0 and then no-opped or crashed, which made a green check
// worse than no check: it is the gate a training pipeline trusts,
// and it was signing off on code that could not run.
//
// The counter-tests matter as much as the positives. A qualifier
// the analyser merely *cannot* verify — a plugin namespace, a
// chain that mentions one — must stay accepted, because `aro
// check` does not load plugins and erroring on the unknowable
// would break correct programs.

import Testing
@testable import AROParser

@Suite("Collection ops rejected at check time (#465)")
struct CollectionOpValidatorTests {

    /// Compiles a feature-set body and returns its error messages.
    private func errors(_ body: String) -> [String] {
        let source = """
        (Check: Demo) {
        \(body)
            Return an <OK: status> for the <check>.
        }
        """
        let result = Compiler().compile(source)
        return result.diagnostics
            .filter { $0.severity == .error }
            .map(\.message)
    }

    private func hints(_ body: String) -> [String] {
        let source = """
        (Check: Demo) {
        \(body)
            Return an <OK: status> for the <check>.
        }
        """
        return Compiler().compile(source).diagnostics
            .filter { $0.severity == .error }
            .flatMap(\.hints)
    }

    // MARK: - The four cases from the issue

    @Test("`Compute the <s: sort>` is an error, not an unsorted list")
    func sortQualifierRejected() {
        let messages = errors("""
                Create the <x> with [3,1,2].
                Compute the <s: sort> from the <x>.
        """)
        #expect(messages.contains { $0.contains("Unknown Compute qualifier 'sort'") })
    }

    @Test("`Compute the <r: reverse>` is an error, not an unchanged list")
    func reverseQualifierRejected() {
        let messages = errors("""
                Create the <x> with [3,1,2].
                Compute the <r: reverse> from the <x>.
        """)
        #expect(messages.contains { $0.contains("Unknown Compute qualifier 'reverse'") })
    }

    @Test("`Compute the <t: first> … with 3` is an error, not the whole list")
    func firstQualifierRejected() {
        let messages = errors("""
                Create the <x> with [3,1,2,9,8].
                Compute the <t: first> from the <x> with 3.
        """)
        #expect(messages.contains { $0.contains("Unknown Compute qualifier 'first'") })
    }

    @Test("`Map … with <expression>` is an error, not `Undefined variable: item`")
    func mapWithExpressionRejected() {
        let messages = errors("""
                Create the <x> with [1,2,3].
                Map the <d> from the <x> with <item> * 0.9.
        """)
        #expect(messages.contains { $0.contains("Map ignores its 'with' value") })
    }

    // MARK: - The hints are the point

    @Test("The sort diagnostic names the action that works")
    func sortHintNamesTheAction() {
        let given = hints("    Compute the <s: sort> from the <x>.")
        #expect(given.contains { $0.contains("Sort the <s> for the <x>.") })
    }

    @Test("The reverse diagnostic names the action that works")
    func reverseHintNamesTheAction() {
        let given = hints("    Compute the <r: reverse> from the <x>.")
        #expect(given.contains { $0.contains("Reverse the <r> for the <x>.") })
    }

    @Test("The first diagnostic names the Extract spelling that works")
    func firstHintNamesExtract() {
        let given = hints("    Compute the <t: first> from the <x>.")
        #expect(given.contains { $0.contains("Extract the <t: first> from the <x>.") })
    }

    @Test("A typo gets a nearest-match hint")
    func typoSuggestsNearestBuiltIn() {
        let given = hints("    Compute the <u: uppercse> from the <x>.")
        #expect(given.contains { $0.contains("uppercase") })
    }

    @Test("A type name in the qualifier slot is redirected to `as`", arguments: [
        "Money", "OrderTotals", "Float",
    ])
    func typeNameSuggestsAsClause(type: String) {
        // ARO-0014 wrote `Compute the <shipping-cost: Money> from { … }`
        // for years. The qualifier slot picks an operation and `as`
        // requests a type — GitLab #475 split them apart precisely
        // because conflating them silently discarded the operation.
        let given = hints("    Compute the <cost: \(type)> from the <order>.")
        #expect(given.contains { $0.contains("as \(type)") })
    }

    @Test("The Map diagnostic names both working spellings")
    func mapHintsNameBothSpellings() {
        let given = hints("    Map the <d> from the <x> with <item> * 0.9.")
        #expect(given.contains { $0.contains("with fieldName.") })
        #expect(given.contains { $0.contains("<d: fieldName>") })
    }

    // MARK: - Everything that must keep working

    @Test("Built-in qualifiers are accepted", arguments: [
        "Compute the <n: length> from the <text>.",
        "Compute the <u: uppercase> from the <text>.",
        "Compute the <d: sha256> from the <text>.",
        "Compute the <t: trim> from the <text>.",
        "Compute the <ls: lines> from the <text>.",
        "Compute the <c: join> from the <items> with { separator: \", \" }.",
        "Compute the <e: base64url-encode> from the <text>.",
        "Compute the <o: replace> from <text> with { find: \"-\", replace: \"_\" }.",
    ])
    func builtInsAccepted(line: String) {
        #expect(errors("    \(line)").isEmpty)
    }

    @Test("A Compute with no qualifier is not this check's business")
    func bareComputeAccepted() {
        #expect(errors("    Compute the <total> from <a> + <b>.").isEmpty)
    }

    @Test("The legacy spelling where the name *is* the operation still checks")
    func legacyNameAsOperationAccepted() {
        // `Compute the <length> from the <message>.` — no specifier, so
        // the runtime resolves the operation from the base name.
        #expect(errors("    Compute the <length> from the <message>.").isEmpty)
    }

    @Test("Plugin qualifiers are unknowable here and stay accepted", arguments: [
        "Compute the <r: collections.reverse> from the <items>.",
        "Compute the <s: stats.sort> from the <scores>.",
        "Compute the <p: Collections.pick-random> from the <items>.",
    ])
    func pluginQualifiersAccepted(line: String) {
        // `aro check` does not load plugins. Erroring on a namespaced
        // name would reject correct programs — the exact failure this
        // change exists to prevent, pointed the other way.
        #expect(errors("    \(line)").isEmpty)
    }

    @Test("Qualifier chains stay accepted", arguments: [
        "Compute the <t: stats.sort | list.take> from the <scores> with { count: 3 }.",
        "Compute the <s: collections.reverse | collections.pick-random> from the <items>.",
    ])
    func chainsAccepted(line: String) {
        #expect(errors("    \(line)").isEmpty)
    }

    @Test("Date offsets stay accepted", arguments: [
        "Compute the <then: -7d> from the <now>.",
        "Compute the <soon: +24h> from the <now>.",
        "Compute the <later: +1M> from the <now>.",
    ])
    func dateOffsetsAccepted(line: String) {
        #expect(errors("    \(line)").isEmpty)
    }

    @Test("A quoted qualifier is a value, not an operation")
    func literalQualifierAccepted() {
        #expect(errors("    Compute the <file: \"data.json\"> from the <dir>.").isEmpty)
    }

    @Test("The Map field projection keeps checking clean", arguments: [
        "Map the <names> from the <users> with name.",
        "Map the <names: name> from the <users>.",
        "Map the <summaries: List<UserSummary>> from the <users>.",
    ])
    func mapProjectionAccepted(line: String) {
        #expect(errors("    \(line)").isEmpty)
    }

    @Test("Other verbs keep their with-clause", arguments: [
        "Create the <u> with { name: \"a\" }.",
        "Emit a <Thing: event> with <payload>.",
        "Filter the <adults> from the <users> where <age> > 27.",
    ])
    func otherVerbsUnaffected(line: String) {
        #expect(errors("    \(line)").isEmpty)
    }

    // MARK: - Catalog rules

    @Test("Date-offset detection matches the runtime's pattern", arguments: [
        "-7d", "+24h", "+1M", "+1w", "3days", "-2 weeks",
    ])
    func offsetPatterns(text: String) {
        // `-2 weeks` has a space and is deliberately *not* an offset
        // by this pattern — recorded so a change to either side is a
        // visible decision, not a surprise.
        let expected = !text.contains(" ")
        #expect(ComputeQualifierCatalog.isDateOffset(text) == expected)
    }

    @Test("Nested statements are validated too")
    func nestedStatementsChecked() {
        let messages = errors("""
                Create the <xs> with [[3,1],[2,9]].
                for each <row> in <xs> {
                    Compute the <s: sort> from the <row>.
                }
        """)
        #expect(messages.contains { $0.contains("Unknown Compute qualifier 'sort'") })
    }
}
