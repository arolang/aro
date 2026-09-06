// ============================================================
// SleepDurationTests.swift
// AROParser — Sleep duration units and the bare-seconds warning
// (GitLab #502)
// ============================================================
//
// `Sleep the <pause> with 300.` sleeps five minutes; a large bare
// number reads like milliseconds to anyone from other ecosystems and
// the symptom is a hang. Two defences, both under test here:
//
//   1. Suffix units parse — `for 300ms`, `for 1.5s`, `for 2m` — and
//      the unit word lands in the object base where SleepAction reads
//      it. Bare numbers stay seconds.
//   2. `aro check` warns on a bare unitless literal over 60, and
//      stays silent whenever a unit is spelled out.

import Testing
@testable import AROParser

@Suite("Sleep Duration Units")
struct SleepDurationUnitTests {

    /// Parses one Sleep statement and returns (unit word in the object
    /// base, literal value the parser attached).
    private func parseSleep(_ statement: String) throws -> (unit: String, value: LiteralValue?) {
        let result = Compiler.compile("""
        (Application-Start: T) {
            \(statement)
            Return an <OK: status> for the <t>.
        }
        """)
        #expect(result.isSuccess, "expected clean compile, got: \(result.diagnostics.map(\.message))")
        let statements = result.program.featureSets[0].statements
        let aro = try #require(statements.first as? AROStatement)
        let literal = (aro.valueSource.asExpression as? LiteralExpression)?.value
            ?? aro.valueSource.asLiteral
        return (aro.object.noun.base, literal)
    }

    @Test("for 300ms — unspaced millisecond suffix")
    func testMillisecondSuffix() throws {
        let parsed = try parseSleep("Sleep the <pause> for 300ms.")
        #expect(parsed.unit == "ms")
        #expect(parsed.value == .integer(300))
    }

    @Test("for 2s — unspaced second suffix")
    func testSecondSuffix() throws {
        let parsed = try parseSleep("Sleep the <pause> for 2s.")
        #expect(parsed.unit == "s")
        #expect(parsed.value == .integer(2))
    }

    @Test("for 1.5s — fractional value keeps its suffix")
    func testFractionalSecondSuffix() throws {
        let parsed = try parseSleep("Sleep the <pause> for 1.5s.")
        #expect(parsed.unit == "s")
        #expect(parsed.value == .float(1.5))
    }

    @Test("for 2m — minute suffix (new in #502)")
    func testMinuteSuffix() throws {
        // `m` follows ARO-0041 §2.3 (`+30m` is thirty minutes). It was
        // missing from the unit table, so `for 2m` was a parse error.
        let parsed = try parseSleep("Sleep the <pause> for 2m.")
        #expect(parsed.unit == "m")
        #expect(parsed.value == .integer(2))
    }

    @Test("with 500 ms — the with preposition takes units too")
    func testWithPrepositionUnit() throws {
        let parsed = try parseSleep("Sleep the <pause> with 500 ms.")
        #expect(parsed.unit == "ms")
        #expect(parsed.value == .integer(500))
    }

    @Test("for 30 seconds — spelled-out words still parse")
    func testSpelledOutUnit() throws {
        let parsed = try parseSleep("Sleep the <pause> for 30 seconds.")
        #expect(parsed.unit == "seconds")
        #expect(parsed.value == .integer(30))
    }

    @Test("Bare number stays seconds (backward compatible)")
    func testBareNumberHasNoUnit() throws {
        let parsed = try parseSleep("Sleep the <pause> for 5.")
        #expect(parsed.unit == "_expression_")
        #expect(parsed.value == .integer(5))
    }

    @Test("Catalog carries every unit the runtime multiplies by")
    func testCatalogContents() {
        // The exact table SleepAction resolves against; a runtime test
        // (SleepActionTests) asserts the multiplication end.
        #expect(DurationUnitCatalog.multiplier(for: "ms") == 0.001)
        #expect(DurationUnitCatalog.multiplier(for: "s") == 1)
        #expect(DurationUnitCatalog.multiplier(for: "m") == 60)
        #expect(DurationUnitCatalog.multiplier(for: "min") == 60)
        #expect(DurationUnitCatalog.multiplier(for: "h") == 3600)
        #expect(DurationUnitCatalog.multiplier(for: "seconds") == 1)
        #expect(DurationUnitCatalog.multiplier(for: "milliseconds") == 0.001)
        #expect(DurationUnitCatalog.multiplier(for: "pause") == nil)
    }
}

@Suite("Sleep Bare-Seconds Warning")
struct SleepBareSecondsWarningTests {

    private func sleepWarnings(_ statement: String) -> [Diagnostic] {
        Compiler.compile("""
        (Application-Start: T) {
            \(statement)
            Return an <OK: status> for the <t>.
        }
        """).diagnostics.filter { $0.message.contains("Sleep sleeps in seconds") }
    }

    @Test("with 300 warns — the case from the issue")
    func testBareLiteralOverThresholdWarns() {
        let warnings = sleepWarnings("Sleep the <pause> with 300.")
        #expect(warnings.count == 1)
        #expect(warnings[0].severity == .warning)
        #expect(warnings[0].message.contains("300 is 5 minutes"))
        #expect(warnings[0].hints.contains { $0.contains("300s") && $0.contains("300ms") })
    }

    @Test("for 90 warns too — both prepositions covered")
    func testForPrepositionWarns() {
        let warnings = sleepWarnings("Sleep the <pause> for 90.")
        #expect(warnings.count == 1)
        #expect(warnings[0].message.contains("1.5 minutes"))
    }

    @Test("A unit silences the warning: for 300s")
    func testUnitSilencesWarning() {
        #expect(sleepWarnings("Sleep the <pause> for 300s.").isEmpty)
    }

    @Test("A spelled-out unit silences it too: for 300 seconds")
    func testSpelledOutUnitSilencesWarning() {
        #expect(sleepWarnings("Sleep the <pause> for 300 seconds.").isEmpty)
    }

    @Test("Milliseconds never warn: for 5000ms")
    func testMillisecondsDoNotWarn() {
        #expect(sleepWarnings("Sleep the <pause> for 5000ms.").isEmpty)
    }

    @Test("Small bare numbers stay silent")
    func testSmallBareNumberDoesNotWarn() {
        #expect(sleepWarnings("Sleep the <pause> for 0.3.").isEmpty)
        #expect(sleepWarnings("Sleep the <pause> for 60.").isEmpty)
        #expect(sleepWarnings("Sleep the <pause> with 5.").isEmpty)
    }

    @Test("Variable durations are not judged")
    func testVariableDurationDoesNotWarn() {
        let warnings = sleepWarnings("""
        Create the <wait-time> with 300.
            Sleep the <pause> for <wait-time>.
        """)
        #expect(warnings.isEmpty)
    }

    @Test("The warning is a warning — the program still compiles")
    func testWarningDoesNotFailCompile() {
        let result = Compiler.compile("""
        (Application-Start: T) {
            Sleep the <pause> with 300.
            Return an <OK: status> for the <t>.
        }
        """)
        #expect(!result.hasErrors)
    }

    @Test("Delay and Pause verbs get the same warning")
    func testAliasVerbsWarn() {
        #expect(sleepWarnings("Delay the <pause> with 120.").count == 1)
        #expect(sleepWarnings("Pause the <pause> with 120.").count == 1)
    }
}
