// ============================================================
// ValueBearingDefaultTests.swift
// AROParser — `default` over a system object's field (GitLab #590)
// ============================================================
//
// `<params: port> default 8080` reads as an expression so a missing `--port`
// is *absent* and the fallback answers it. `<queryParameters: limit>
// default 10` did not: framework objects were kept as object clauses
// wholesale, so an omitted `?limit=` failed the statement instead — the one
// case the fallback exists for.
//
// The exclusion is not arbitrary. `<file: "notes.md">` is an *address* an
// action resolves; routed through the expression grammar it would find no
// variable called `file` and hand back the default every single time. So the
// rule is per-base: a system object joins the expression grammar only if the
// expression evaluator can actually read it.

import Testing
@testable import AROParser

@Suite("`default` over system-object fields (#590)")
struct ValueBearingDefaultTests {

    private func valueSourceIsExpression(_ statement: String) -> Bool {
        let result = Compiler.compile("""
        (Application-Start: T) {
            \(statement)
            Return an <OK: status> for the <t>.
        }
        """)
        guard let aro = result.program.featureSets.first?.statements.first as? AROStatement
        else { return false }
        return aro.valueSource.asExpression != nil
    }

    // MARK: - Records of values read `default` as an operator

    @Test("HTTP request-context records reach the expression grammar")
    func contextRecordsAreExpressions() {
        #expect(valueSourceIsExpression("Create the <l> with <queryParameters: limit> default 10."))
        #expect(valueSourceIsExpression("Create the <i> with <pathParameters: id> default \"none\"."))
    }

    @Test("The bases that already worked keep working")
    func existingBasesUnchanged() {
        #expect(valueSourceIsExpression("Create the <p> with <parameter: port> default 8080."))
        #expect(valueSourceIsExpression("Create the <e> with <env: HOME> default \"/tmp\"."))
    }

    @Test("Action arguments and event payloads are records too")
    func inputAndEventAreExpressions() {
        #expect(valueSourceIsExpression("Create the <n> with <input: number> default 7."))
        #expect(valueSourceIsExpression("Create the <w> with <event: who> default \"nobody\"."))
    }

    @Test("An ordinary variable was never affected")
    func plainVariablesUnchanged() {
        #expect(valueSourceIsExpression("Create the <x> with <settings: retries> default 3."))
    }

    // MARK: - Addresses must stay object clauses

    @Test("`file` stays an address — promoting it would default on every read")
    func fileStaysAnObject() {
        // There is no variable called `file` for an expression to read, so the
        // fallback would win even when the file is there.
        #expect(!valueSourceIsExpression("Read the <c> from the <file: \"notes.md\"> default \"none\"."))
    }

    @Test("`request` stays an address — a body is consumed once (ARO-0090)")
    func requestStaysAnObject() {
        #expect(!valueSourceIsExpression("Create the <b> with <request: body> default \"empty\"."))
    }

    @Test("`headers` stays an address — it does not resolve as a record")
    func headersStayAnObject() {
        // Checked against the runtime: even `Extract the <h> from the <headers>.`
        // fails, so an expression read would answer the default for a header
        // that was actually sent.
        #expect(!valueSourceIsExpression("Create the <a> with <headers: x-agent> default \"none\"."))
    }

    // MARK: - The catalog itself

    @Test("Every value-bearing base is also a system object")
    func valueBearingNamesAreSystemObjects() {
        for name in SystemObjectCatalog.valueBearingNames {
            #expect(SystemObjectCatalog.isSystemObject(name), "\(name)")
        }
    }

    @Test("isValueBearing is case-insensitive, like isSystemObject")
    func caseInsensitive() {
        #expect(SystemObjectCatalog.isValueBearing("queryParameters"))
        #expect(SystemObjectCatalog.isValueBearing("QUERYPARAMETERS"))
        #expect(!SystemObjectCatalog.isValueBearing("file"))
    }
}
