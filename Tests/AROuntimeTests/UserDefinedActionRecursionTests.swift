// ============================================================
// UserDefinedActionRecursionTests.swift
// ARO Runtime - Recursion in user-defined actions (ARO-0081, GitLab #473)
// ============================================================
//
// Before these, a recursive user-defined action died on SIGBUS at ~1 300
// frames with no output whatsoever — no ARO error, no partial log, and
// `aro check` called the program clean. What follows pins down the behaviour
// that replaced it: depth bounded by memory rather than by the native stack,
// tail calls that reuse their frame, and a runaway recursion that says so.

import Foundation
import Testing
@testable import ARORuntime
@testable import AROParser

@Suite("User-Defined Action Recursion (ARO-0081)", .serialized)
struct UserDefinedActionRecursionTests {

    /// Compile and run a snippet, returning the `Application-Start` response.
    ///
    /// Teardown removes only this program's verbs: the registry is
    /// process-wide, and suites run in parallel, so clearing everything would
    /// unregister another suite's actions mid-run.
    private func runProgram(_ source: String) async throws -> Response {
        let result = Compiler().compile(source)
        #expect(result.diagnostics.allSatisfy { $0.severity != .error },
                "Compilation produced unexpected errors: \(result.diagnostics.map(\.message))")
        let runtime = Runtime()
        defer {
            let host = UserDefinedActionHost(
                analyzedProgram: result.analyzedProgram,
                globalSymbols: GlobalSymbolStorage()
            )
            ActionRegistry.shared.unregisterDynamic(
                verbs: host.actionNames.map { "Application.\($0)" }
            )
        }
        return try await runtime.run(result.analyzedProgram)
    }

    /// A recursion that inspects each result, so every frame stays live.
    /// `depth` frames of real nesting — the shape that used to crash.
    private func countingProgram(depth: Int) -> String {
        """
        (CountDown: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Return an <OK: status> with { total: 0 } when <v> <= 0.
            Compute the <next> from <v> - 1.
            Application.CountDown the <r> from <next>.
            Extract the <sub> from the <r: total>.
            Compute the <total> from <sub> + 1.
            Return an <OK: status> with { total: <total> }.
        }
        (Application-Start: Demo) {
            Application.CountDown the <result> from \(depth).
            Extract the <total> from the <result: total>.
            Return an <OK: status> with { total: <total> }.
        }
        """
    }

    /// The same countdown written so the call is in tail position: the frame
    /// forwards the callee's result untouched, so it can be reused.
    private func tailProgram(depth: Int) -> String {
        """
        (CountDown: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Return an <OK: status> with { reached: <v> } when <v> <= 0.
            Compute the <next> from <v> - 1.
            Application.CountDown the <r> from <next>.
            Return an <OK: status> with <r>.
        }
        (Application-Start: Demo) {
            Application.CountDown the <result> from \(depth).
            Extract the <reached> from the <result: reached>.
            Return an <OK: status> with { reached: <reached> }.
        }
        """
    }

    private func intValue(_ response: Response, _ key: String) -> Int? {
        guard let raw: any Sendable = response.data[key]?.get() else { return nil }
        if let i = raw as? Int { return i }
        if let d = raw as? Double { return Int(d) }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    // MARK: - Depth

    @Test("Recursion far past the old ~1300-frame ceiling completes")
    func deepRecursionCompletes() async throws {
        // 2 500 live frames: comfortably past where the native stack used to
        // give out, and cheap enough not to dominate the suite on a CI runner.
        let response = try await runProgram(countingProgram(depth: 2_500))
        #expect(response.status == "OK")
        #expect(intValue(response, "total") == 2_500)
    }

    @Test("A correct recursion with a base case still returns the right answer")
    func shallowRecursionIsCorrect() async throws {
        let response = try await runProgram(countingProgram(depth: 7))
        #expect(intValue(response, "total") == 7)
    }

    @Test("Mutual recursion terminates on its base case")
    func mutualRecursionTerminates() async throws {
        let source = """
        (Ping: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Return an <OK: status> with { hops: 0 } when <v> <= 0.
            Compute the <next> from <v> - 1.
            Application.Pong the <r> from <next>.
            Extract the <sub> from the <r: hops>.
            Compute the <hops> from <sub> + 1.
            Return an <OK: status> with { hops: <hops> }.
        }
        (Pong: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Return an <OK: status> with { hops: 0 } when <v> <= 0.
            Compute the <next> from <v> - 1.
            Application.Ping the <r> from <next>.
            Extract the <sub> from the <r: hops>.
            Compute the <hops> from <sub> + 1.
            Return an <OK: status> with { hops: <hops> }.
        }
        (Application-Start: Demo) {
            Application.Ping the <result> from 20.
            Extract the <hops> from the <result: hops>.
            Return an <OK: status> with { hops: <hops> }.
        }
        """
        let response = try await runProgram(source)
        #expect(intValue(response, "hops") == 20)
    }

    // MARK: - Tail calls

    @Test("Tail recursion reuses its frame, so the depth budget never sees it")
    func tailRecursionDoesNotAccumulateFrames() async throws {
        // The proof is the budget: 2 000 tail calls under a budget of 10 can
        // only pass if the frames are being reused rather than stacked.
        let original = RuntimeDefaults.maxUserActionDepth
        RuntimeDefaults.maxUserActionDepth = 10
        defer { RuntimeDefaults.maxUserActionDepth = original }

        let response = try await runProgram(tailProgram(depth: 2_000))
        #expect(response.status == "OK")
        #expect(intValue(response, "reached") == 0)
    }

    @Test("A call whose result is destructured is not a tail call")
    func destructuringIsNotATailCall() async throws {
        // `Extract … from the <r: total>` is work after the call, so the frame
        // is still needed and the budget must count it.
        let original = RuntimeDefaults.maxUserActionDepth
        RuntimeDefaults.maxUserActionDepth = 10
        defer { RuntimeDefaults.maxUserActionDepth = original }

        await #expect(throws: (any Error).self) {
            _ = try await runProgram(countingProgram(depth: 50))
        }
    }

    @Test("Tail-call detection accepts only the exact forwarding shape")
    func tailCallDetection() throws {
        func featureSet(_ source: String) throws -> FeatureSet {
            let result = Compiler().compile(source)
            let action = result.analyzedProgram.featureSets.first { $0.featureSet.isUserAction }
            return try #require(
                action?.featureSet,
                "no Action feature set compiled: \(result.diagnostics.map(\.message))"
            )
        }

        let forwarding = try featureSet("""
        (Loop: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Loop the <r> from <v>.
            Return an <OK: status> with <r>.
        }
        (Application-Start: Demo) {
            Return an <OK: status> for the <s>.
        }
        """)
        #expect(TailCallAnalysis.tailCallStatementIndex(of: forwarding) == 1)

        let destructuring = try featureSet("""
        (Loop: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Loop the <r> from <v>.
            Extract the <d> from the <r: total>.
            Return an <OK: status> with <d>.
        }
        (Application-Start: Demo) {
            Return an <OK: status> for the <s>.
        }
        """)
        #expect(TailCallAnalysis.tailCallStatementIndex(of: destructuring) == nil)

        let guardedReturn = try featureSet("""
        (Loop: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Loop the <r> from <v>.
            Return an <OK: status> with <r> when <v> > 0.
        }
        (Application-Start: Demo) {
            Return an <OK: status> for the <s>.
        }
        """)
        #expect(TailCallAnalysis.tailCallStatementIndex(of: guardedReturn) == nil)
    }

    // MARK: - Runaway diagnostics

    @Test("A recursion with no base case reports the budget instead of dying")
    func runawayRecursionReportsCallChain() async throws {
        let original = RuntimeDefaults.maxUserActionDepth
        RuntimeDefaults.maxUserActionDepth = 200
        defer { RuntimeDefaults.maxUserActionDepth = original }

        let source = """
        (Forever: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Compute the <next> from <v> + 1.
            Application.Forever the <r> from <next>.
            Extract the <d> from the <r: depth>.
            Return an <OK: status> with { depth: <d> }.
        }
        (Application-Start: Demo) {
            Application.Forever the <result> from 1.
            Return an <OK: status> for the <startup>.
        }
        """

        var reported: String?
        do {
            _ = try await runProgram(source)
        } catch {
            reported = String(describing: error)
        }

        let message = try #require(reported, "runaway recursion should surface an error")
        #expect(message.contains("call-depth budget"))
        #expect(message.contains("Forever"))
        #expect(message.contains("ARO_MAX_CALL_DEPTH"))
    }

    @Test("The budget can be switched off")
    func budgetCanBeDisabled() async throws {
        let original = RuntimeDefaults.maxUserActionDepth
        RuntimeDefaults.maxUserActionDepth = 0
        defer { RuntimeDefaults.maxUserActionDepth = original }

        // 300 real frames under a disabled budget: no ceiling applies.
        let response = try await runProgram(countingProgram(depth: 300))
        #expect(intValue(response, "total") == 300)
    }

    // MARK: - Static detection

    @Test("aro check warns about a recursion that can never reach a base case")
    func staticWarningForUnconditionalSelfRecursion() {
        let result = Compiler().compile("""
        (Forever: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Forever the <r> from <v>.
            Return an <OK: status> with <r>.
        }
        (Application-Start: Demo) {
            Application.Forever the <x> from 1.
            Return an <OK: status> for the <startup>.
        }
        """)
        let warnings = result.diagnostics.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.contains { $0.contains("always calls itself") })
    }

    @Test("aro check warns about an unavoidable mutual cycle")
    func staticWarningForMutualRecursion() {
        let result = Compiler().compile("""
        (Ping: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Pong the <r> from <v>.
            Return an <OK: status> with <r>.
        }
        (Pong: Action takes <n>) {
            Extract the <v> from the <input: n>.
            Application.Ping the <r> from <v>.
            Return an <OK: status> with <r>.
        }
        (Application-Start: Demo) {
            Application.Ping the <x> from 1.
            Return an <OK: status> for the <startup>.
        }
        """)
        let warnings = result.diagnostics.filter { $0.severity == .warning }.map(\.message)
        #expect(warnings.contains { $0.contains("Ping → Pong → Ping") })
    }

    @Test("A recursion with a guarded base case is not warned about")
    func noStaticWarningWhenBaseCaseExists() {
        let result = Compiler().compile(countingProgram(depth: 3))
        let warnings = result.diagnostics.filter { $0.severity == .warning }.map(\.message)
        #expect(!warnings.contains { $0.contains("no base case") })
    }
}
