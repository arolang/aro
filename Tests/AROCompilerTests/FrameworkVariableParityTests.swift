// ============================================================
// FrameworkVariableParityTests.swift
// AROCompiler Tests — compiled mode sweeps what interpreted mode
// sweeps (GitLab #552)
// ============================================================
//
// A statement's modifiers reach its action through `_`-prefixed
// variables in the execution context, so the context has to be
// swept between statements or the next statement inherits them.
// Both modes swept — different sets. The interpreter cleared 21
// names; the code generator emitted `aro_variable_unbind` for a
// hand-written 14, and the seven it missed made `aro run` and
// `aro build` print different answers for the same program:
//
//     Compute the <j1: join> from <one> with { separator: "-" }.
//     Compute the <j2: join> from <two>.        (* no `with` *)
//
// interpreted `cd`, compiled `c-d`.
//
// Both lists are now `FrameworkVariables.transientKeys`, and since
// GitLab #714 the compiled path does not spell the sweep out in IR
// at all: it emits one `aro_context_clear_transients` call, and the
// runtime side of that bridge calls the same
// `clearTransientFrameworkVariables()` the interpreter calls. So
// "the emitted program clears every name in the constant" is no
// longer something a test can lose — one function reads the
// constant, at run time, in both modes.
//
// What a test can still lose is the *call*. A statement that never
// clears inherits the previous statement's modifiers, which is
// exactly #552 again, so that is what these assert: every statement
// emits the sweep, and it emits it before the modifiers it binds.

import Foundation
import Testing
@testable import AROCompiler
@testable import AROParser

#if !os(Windows)

@Suite("Framework variable parity between run and build (#552)")
struct FrameworkVariableParityTests {

    // MARK: - Helpers

    /// Compile ARO source all the way to LLVM IR text.
    private func generateIR(_ source: String) throws -> String {
        let compiler = Compiler()
        let result = compiler.compile(source)
        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty,
                "compilation failed: \(errors.map(\.message).joined(separator: "; "))")
        let generator = LLVMCodeGenerator()
        return try generator.generate(program: result.analyzedProgram).irText
    }

    /// Every call the module makes, in emission order, as bare function names.
    private func callSequence(inIR ir: String) -> [String] {
        var calls: [String] = []
        for rawLine in ir.split(separator: "\n") {
            guard let marker = rawLine.range(of: "call ") else { continue }
            guard let at = rawLine[marker.upperBound...].firstIndex(of: "@") else { continue }
            let rest = rawLine[rawLine.index(after: at)...]
            guard let open = rest.firstIndex(of: "(") else { continue }
            calls.append(String(rest[..<open]))
        }
        return calls
    }

    /// The variable names the module actually calls `aro_variable_unbind` on.
    ///
    /// Resolves the private string globals the calls point at, so this reads
    /// the emitted program rather than the Swift array that produced it:
    ///
    ///     @.str.19 = private constant [7 x i8] c"_with_\00"
    ///     call void @aro_variable_unbind(ptr %0, ptr @.str.19)
    private func unboundNames(inIR ir: String) -> Set<String> {
        var literals: [String: String] = [:]
        var unbound: Set<String> = []

        for rawLine in ir.split(separator: "\n") {
            let line = String(rawLine)

            if line.hasPrefix("@.str."), let equals = line.firstIndex(of: "="),
               let open = line.range(of: " c\""), let close = line.lastIndex(of: "\"") {
                let global = String(line[line.startIndex..<equals])
                    .trimmingCharacters(in: .whitespaces)
                var value = String(line[open.upperBound..<close])
                if value.hasSuffix("\\00") { value.removeLast(3) }
                literals[global] = value
                continue
            }

            guard line.contains("@aro_variable_unbind("),
                  let marker = line.range(of: "ptr @", options: .backwards) else { continue }
            var operand = String(line[marker.upperBound...])
            if let end = operand.firstIndex(where: { $0 == ")" || $0 == "," }) {
                operand = String(operand[..<end])
            }
            if let name = literals["@" + operand] { unbound.insert(name) }
        }
        return unbound
    }

    /// The issue's repro, plus statements that exercise the other clause kinds.
    private static let probe = """
    (Application-Start: Probe) {
        Compute the <one> as List from ["a", "b"].
        Compute the <j1: join> from <one> with { separator: "-" }.
        Compute the <two> as List from ["c", "d"].
        Compute the <j2: join> from <two>.
        Log <j1> to the <console>.
        Log <j2> to the <console>.
        Return an <OK: status> for the <probe>.
    }
    """

    // MARK: - The parity invariant

    @Test("Every statement clears its framework variables before binding new ones")
    func everyStatementSweeps() throws {
        let calls = callSequence(inIR: try generateIR(Self.probe))
        let sweeps = calls.filter { $0 == "aro_context_clear_transients" }

        // The probe has seven statements. The bound is a floor rather than an
        // equality: a `when` guard or a loop can legitimately add prologues,
        // and this test exists to catch the sweep disappearing, not to pin the
        // generator's shape.
        #expect(sweeps.count >= 7,
                Comment(rawValue: "only \(sweeps.count) sweeps for a seven-statement"
                        + " program — a statement that does not clear inherits the"
                        + " previous one's modifiers (#552)"))

        // Order is the whole point: clearing after binding would erase the
        // statement's own `with` clause instead of the previous statement's.
        let firstSweep = calls.firstIndex(of: "aro_context_clear_transients")
        let firstBind = calls.firstIndex { $0.hasPrefix("aro_variable_bind") }
        if let firstSweep, let firstBind {
            #expect(firstSweep < firstBind,
                    "the sweep runs after the first modifier binding, which would clear the statement's own clause")
        }
    }

    @Test("The sweep is not spelled out one unbind call at a time")
    func theSweepIsNotEmittedNameByName() throws {
        // 21 `aro_variable_unbind` calls before every statement was the cost
        // #714 was filed about: each one a C-ABI crossing, a `String(cString:)`
        // and a dictionary removal that almost always found nothing.
        //
        // `aro_variable_unbind` itself stays — loop variables and pipeline
        // bindings are unbound by name — so this asserts about the operands,
        // not about the call. The string constants also stay: `bindQueryModifiers`
        // still binds `_where_field_` and friends by name.
        let unbound = unboundNames(inIR: try generateIR(Self.probe))
        let sweptByName = FrameworkVariables.transientKeys.filter { unbound.contains($0) }
        #expect(sweptByName.isEmpty,
                Comment(rawValue: "the per-name sweep is back for "
                        + sweptByName.joined(separator: ", ")
                        + " — that is 21 bridge calls per statement (#714)"))
    }

    @Test("Neither list is empty, so an empty-set parity pass cannot be vacuous")
    func theListIsNotEmpty() {
        // A parity assertion over an empty constant passes for the wrong
        // reason. 21 is the count at the time of #552; the bound is a floor,
        // not an equality, so adding a modifier does not fail the suite.
        #expect(FrameworkVariables.transientKeys.count >= 21)
        #expect(Set(FrameworkVariables.transientKeys).count
                == FrameworkVariables.transientKeys.count,
                "duplicate entry in transientKeys")
    }
}

#endif
