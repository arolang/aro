// ============================================================
// CurrencyNumberFormatTests.swift
// ARO Runtime — the `Currency` number format (GitLab #906)
// ============================================================
//
// `Compute the <line-total> from <qty> * <price>.` with 3 and 2.40 is
// 7.199999999999999, and ARO used to teach that limitation rather than fix
// it. `as Currency` makes the arithmetic exact where the amount is produced,
// so `fixed` has nothing left to repair and a gold-layer CSV cannot ship
// `99.94999999999999` (GitLab #517) in the first place.
//
// Three things are asserted here, and the third is the one that matters most:
//
//   1. the arithmetic is exact, and division rounds by a *stated* rule,
//   2. an exact amount serialises as a NUMBER at full precision in every
//      sink — JSON, CSV, YAML, console, HTTP body,
//   3. `aro run` and `aro build` agree, operator by operator. The compiled
//      path dropped the `as <Type>` annotation entirely before #906 (the C
//      result descriptor has three fields and no slot for it), so every
//      annotated statement behaved differently in the two modes.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("Currency number format (#906)")
struct CurrencyNumberFormatTests {

    // MARK: - The type

    @Test("three items at 2.40 is 7.20, exactly")
    func exactMultiplication() throws {
        let qty = AROCurrency(3)
        let price = try #require(AROCurrency(decimalString: "2.40"))
        let total = try qty.multiplied(by: price)
        #expect(total.description == "7.20")
        #expect(total == AROCurrency(units: 72, scale: 1))
        // The float answer, for contrast — this is what the language used to
        // offer and the documentation used to explain.
        let floatTotal: Double = 3.0 * 2.40
        #expect(floatTotal != 7.2)
    }

    @Test("a Double converts by its decimal spelling, not its bits")
    func readsTheSpelling() throws {
        // A price that entered the program as 2.40 from a CSV arrives as the
        // Double nearest 2.4 and becomes exactly 2.4 — which is what makes an
        // amount that started as a float exact from there on.
        let price = try #require(AROCurrency(2.40))
        #expect(price.description == "2.4")
        #expect(try price.multiplied(by: AROCurrency(3)).description == "7.2")
    }

    @Test("addition and subtraction align scales and stay exact")
    func exactAddition() throws {
        let a = try #require(AROCurrency(decimalString: "19.99"))
        var total = AROCurrency(0)
        for _ in 0..<5 { total = try total.adding(a) }
        #expect(total.description == "99.95")
        // Five floats do not. Hoisted out of the macro: a chain of Double
        // literals inside `#expect` is pathological for the type checker.
        let floatTotal: Double = 19.99 + 19.99 + 19.99 + 19.99 + 19.99
        #expect(floatTotal != 99.95)

        let change = try #require(AROCurrency(decimalString: "100.00"))
        #expect(try change.subtracting(total).description == "0.05")
    }

    @Test("division rounds half-up at six places, then drops trailing zeros")
    func statedDivisionRule() throws {
        let ten = try #require(AROCurrency(decimalString: "10.00"))
        // Not representable: six places, half-up, visibly inexact. That is
        // the honest report, and it is written down.
        #expect(try ten.divided(by: AROCurrency(3)).description == "3.333333")
        // Representable: the zeros come off down to the wider operand scale.
        let six = try #require(AROCurrency(decimalString: "6.00"))
        #expect(try six.divided(by: AROCurrency(2)).description == "3.00")
        // Six places is four more than any circulating minor unit, so an
        // intermediate division never decides the cents.
        #expect(AROCurrency.divisionScale == 6)
    }

    @Test("rescaling rounds half-up away from zero, both signs")
    func halfUpRounding() throws {
        let up = try #require(AROCurrency(decimalString: "2.345"))
        #expect(try up.rescaled(to: 2).description == "2.35")
        let down = try #require(AROCurrency(decimalString: "-2.345"))
        #expect(try down.rescaled(to: 2).description == "-2.35")
        #expect(try up.rescaled(to: 0).description == "2")
    }

    @Test("division by zero is an error, not an infinity")
    func divisionByZero() throws {
        let one = AROCurrency(1)
        #expect(throws: AROCurrencyError.self) {
            try one.divided(by: AROCurrency(0))
        }
    }

    @Test("an unrepresentable result is named, never wrapped")
    func overflowIsReported() throws {
        let big = AROCurrency(units: Int.max, scale: 0)
        #expect(throws: AROCurrencyError.self) { try big.adding(big) }
        // Multiplication is what reaches the scale limit first: the scales add.
        let deep = AROCurrency(units: 1, scale: 10)
        #expect(throws: AROCurrencyError.self) { try deep.multiplied(by: deep) }
    }

    @Test("equality is by value, so 7.2 equals 7.20")
    func valueEquality() throws {
        let short = try #require(AROCurrency(decimalString: "7.2"))
        let long = try #require(AROCurrency(decimalString: "7.20"))
        #expect(short == long)
        #expect(short.hashValue == long.hashValue)
        // And the scale each was written at survives for rendering.
        #expect(short.description == "7.2")
        #expect(long.description == "7.20")
    }

    @Test("negative amounts render and compare correctly")
    func negatives() throws {
        let debit = try #require(AROCurrency(decimalString: "-0.05"))
        #expect(debit.description == "-0.05")
        #expect(debit < AROCurrency(0))
        #expect(debit.negated.description == "0.05")
    }

    // MARK: - The annotation

    @Test("`as Currency` and `as Decimal` are the same format")
    func decimalIsNoLongerAnAliasForFloat() {
        #expect(NumberFormatCatalog.format(for: "Currency") == .exact)
        #expect(NumberFormatCatalog.format(for: "Decimal") == .exact)
        #expect(NumberFormatCatalog.format(for: "decimal") == .exact)
        // The defect #906 names: `Decimal` promised exactness and mapped to
        // `floatTypes`, i.e. Double.
        #expect(NumberFormatCatalog.format(for: "Float") == .float)
        #expect(ResultTypeCoercion.requestsFloat("Decimal") == false)
        #expect(ResultTypeCoercion.requestsExact("Decimal"))
    }

    @Test("a numeric annotation forbids build-time constant folding")
    func foldingIsSuppressed() {
        // `3 * 2.40` folded in Double is 7.199999999999999, baked into the
        // binary before the runtime can be exact about it; `7 / 2` folded in
        // Int is 3, which is what `as Float` was written to avoid.
        #expect(NumberFormatCatalog.allowsConstantFolding("Currency") == false)
        #expect(NumberFormatCatalog.allowsConstantFolding("Decimal") == false)
        #expect(NumberFormatCatalog.allowsConstantFolding("Float") == false)
        #expect(NumberFormatCatalog.allowsConstantFolding("Integer") == false)
        // An unannotated statement, and a schema name, fold as before.
        #expect(NumberFormatCatalog.allowsConstantFolding(nil))
        #expect(NumberFormatCatalog.allowsConstantFolding("Money"))
    }

    @Test("the annotation travels as a swept per-statement modifier")
    func asTypeIsATransient() {
        // The compiled path has no AST, so this is how `as <Type>` reaches
        // the expression evaluator and the action. Being in `transientKeys`
        // is what stops it leaking into the next statement.
        #expect(FrameworkVariables.transientKeys.contains("_as_type_"))
    }

    @Test("coercion converts, widens and narrows only when lossless")
    func coercion() throws {
        let exact = ResultTypeCoercion.coerce(2.40 as any Sendable, to: "Currency")
        #expect((exact as? AROCurrency)?.description == "2.4")

        // A non-number is left alone; the action reports it, since only the
        // action knows which statement asked.
        let text = ResultTypeCoercion.coerce("not a price" as any Sendable, to: "Currency")
        #expect(text as? String == "not a price")

        // `as Integer` on an amount with cents refuses to drop them.
        let cents = try #require(AROCurrency(decimalString: "7.20"))
        #expect(ResultTypeCoercion.coerce(cents, to: "Integer") as? AROCurrency == cents)
        let whole = try #require(AROCurrency(decimalString: "7.00"))
        #expect(ResultTypeCoercion.coerce(whole, to: "Integer") as? Int == 7)

        // `as Float` is an explicit request to leave exactness behind.
        #expect(ResultTypeCoercion.coerce(cents, to: "Float") as? Double == 7.2)
    }

    // MARK: - Serialisation: a number, at full precision, in every sink

    private func exactNinetyNine() throws -> AROCurrency {
        let unit = try #require(AROCurrency(decimalString: "19.99"))
        return try unit.multiplied(by: AROCurrency(5))
    }

    @Test("JSON writes it as an unquoted number")
    func jsonIsANumber() throws {
        let row: [String: any Sendable] = ["revenue": try exactNinetyNine()]
        let json = FormatSerializer.serialize(row, format: .json, variableName: "row")
        #expect(json.contains("\"revenue\" : 99.95"))
        // ARO-0019 §3.2.1: a rendered string "would print correctly and then
        // quote itself into a JSON data product, which is a different wrong
        // answer".
        #expect(!json.contains("\"99.95\""))
    }

    @Test("CSV writes the cell GitLab #517 found wrong")
    func csvIsANumber() throws {
        let rows: [any Sendable] = [
            ["region": "EMEA", "revenue": try exactNinetyNine()] as [String: any Sendable]
        ]
        let csv = FormatSerializer.serialize(rows, format: .csv, variableName: "rows")
        #expect(csv.contains("EMEA,99.95"))
        #expect(!csv.contains("99.9499"))
    }

    @Test("YAML and JSONL agree with JSON")
    func otherFormats() throws {
        let row: [String: any Sendable] = ["revenue": try exactNinetyNine()]
        #expect(FormatSerializer.serialize(row, format: .yaml, variableName: "row")
                    .contains("revenue: 99.95"))
        #expect(FormatSerializer.serialize(row, format: .jsonl, variableName: "row")
                    .contains("\"revenue\":99.95"))
    }

    @Test("console output prints the amount, not a re-rendered Double")
    func consoleRendering() throws {
        let amount = try exactNinetyNine()
        #expect(ResponseFormatter.formatValue(amount, for: .human) == "99.95")
    }

    @Test("an HTTP body carrying an amount is written exactly")
    func httpBody() throws {
        // `JSONSerialization` cannot carry the type, and widening it to Double
        // first is the loss the format exists to prevent — so a payload
        // holding one goes through ARO's own writer. GitLab #908 (plain
        // Doubles on this path) is deliberately untouched.
        let payload: [String: Any] = ["revenue": try exactNinetyNine()]
        #expect(ResponseFormatter.containsExactAmount(payload))
        #expect(FormatSerializer.serializeExactJSON(payload) == "{\"revenue\":99.95}")
    }

    // MARK: - Both execution modes, operator by operator

    /// The compiled evaluator's answer for one operator.
    private func compiled(
        _ op: String, _ left: any Sendable, _ right: any Sendable
    ) -> any Sendable {
        evaluateBinaryOp(op: op, left: left, right: right, mode: .exact)
    }

    /// The interpreter's answer for the same operator.
    private func interpreted(
        _ op: String, _ left: any Sendable, _ right: any Sendable
    ) throws -> any Sendable {
        try ExpressionEvaluator.exactOperation(left, right, symbol: op)
    }

    /// `aro run` and `aro build` agree on every exact operator.
    ///
    /// Numeric operands only — including a numeric String, which both modes
    /// read as a number everywhere except `*`.
    ///
    /// `*` with a String operand is repetition, and that precedence sits
    /// *around* the arithmetic rather than in it. The two modes already
    /// disagree about it for a non-Int count (the interpreter truncates the
    /// count and repeats; the compiled path multiplies), which predates this
    /// change and is left alone. `Examples/CurrencyAmounts` is what holds the
    /// two modes to the same output for whole statements, under the dual-mode
    /// integration runner.
    @Test("`aro run` and `aro build` agree on every exact operator")
    func modeParity() throws {
        let cases: [(String, any Sendable, any Sendable)] = [
            ("+", 19.99, 19.99),
            ("-", 100.00, 19.99),
            ("*", 3, 2.40),
            ("/", 10.00, 3),
            ("%", 7.50, 2.00),
            ("+", 1, 2),
            ("+", "2.40", 3),
            ("-", "100.00", "0.05"),
        ]
        for (op, left, right) in cases {
            let a = try interpreted(op, left, right)
            let b = compiled(op, left, right)
            #expect(
                (a as? AROCurrency) == (b as? AROCurrency),
                "\(left) \(op) \(right): run gave \(a), build gave \(b)"
            )
        }
    }

    @Test("an exact operand makes the operation exact without re-annotating")
    func contagion() throws {
        // This is what lets a pipeline compute `line_total` once, exactly,
        // and have every `sum` downstream agree — no `as Currency` on the
        // reading statements.
        let amount = try #require(AROCurrency(decimalString: "7.20"))
        #expect(ExpressionEvaluator.wantsExact(.natural, amount, 1.05))
        #expect(ExpressionEvaluator.wantsExact(.natural, 1.05, amount))
        #expect(!ExpressionEvaluator.wantsExact(.natural, 1.05, 1.05))

        let sum = try ExpressionEvaluator.exactOperation(amount, 1.05, symbol: "+")
        #expect((sum as? AROCurrency)?.description == "8.25")
        // Compiled mode reaches the same branch without any annotation.
        let compiledSum = evaluateBinaryOp(op: "+", left: amount, right: 1.05)
        #expect((compiledSum as? AROCurrency)?.description == "8.25")
    }

    @Test("comparison is exact, not a Double or a string")
    func comparison() throws {
        let a = try #require(AROCurrency(decimalString: "7.20"))
        let b = try #require(AROCurrency(decimalString: "7.19"))
        #expect(evaluateBinaryOp(op: ">", left: a, right: b) as? Bool == true)
        #expect(evaluateBinaryOp(op: "<", left: b, right: a) as? Bool == true)
        // Lexicographically "7.19" < "7.20" too, so pick a pair where the
        // string order is wrong: 10.00 vs 9.00.
        let ten = try #require(AROCurrency(decimalString: "10.00"))
        let nine = try #require(AROCurrency(decimalString: "9.00"))
        #expect(evaluateBinaryOp(op: ">", left: ten, right: nine) as? Bool == true)
    }

    // MARK: - `fixed` keeps its job

    @Test("`fixed` on an amount rescales it and stays exact")
    func fixedStaysExact() async throws {
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "out", specifiers: ["fixed"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "input",
                                      specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: try #require(AROCurrency(decimalString: "7.2")))
        let value = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect((value as? AROCurrency)?.description == "7.20")
    }

    @Test("`sum` of an exact column stays exact")
    func sumStaysExact() async throws {
        let unit = try #require(AROCurrency(decimalString: "19.99"))
        let span = SourceSpan(at: SourceLocation())
        let result = ResultDescriptor(base: "out", specifiers: ["sum"], span: span)
        let object = ObjectDescriptor(preposition: .from, base: "input",
                                      specifiers: [], span: span)
        let context = RuntimeContext(featureSetName: "Test")
        context.bind("input", value: [unit, unit, unit, unit, unit] as [any Sendable])
        let value = try await ComputeAction().execute(
            result: result, object: object, context: context)
        #expect((value as? AROCurrency)?.description == "99.95")
    }
}
