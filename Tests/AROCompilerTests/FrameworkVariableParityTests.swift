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
// Both lists are now `FrameworkVariables.transientKeys`, which
// makes the Swift-level agreement trivially true — so these tests
// assert the thing that is not trivial: that the *emitted IR*
// really unbinds every name in it. A key added to the constant but
// dropped somewhere between the generator and the module fails
// here rather than in a user's binary.

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

    @Test("Compiled statements unbind every framework variable interpreted ones clear")
    func everyTransientKeyIsUnbound() throws {
        let unbound = unboundNames(inIR: try generateIR(Self.probe))
        let missing = FrameworkVariables.transientKeys.filter { !unbound.contains($0) }
        let complaint = "compiled mode never clears " + missing.joined(separator: ", ")
            + " — these leak into the next statement, so `aro build` and `aro run`"
            + " will disagree about any program that reuses the clause (#552)"
        #expect(missing.isEmpty, Comment(rawValue: complaint))
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

    // MARK: - The specific leaks #552 names

    @Test("The `with` clause the join repro leaks on is cleared",
          arguments: ["_with_", "_to_", "_against_", "_literal_",
                      "_expression_", "_expression_name_", "_result_expression_"])
    func namedLeakIsCleared(key: String) throws {
        // The seven names compiled mode used to carry into the next statement.
        // `_with_` is the one the issue's repro trips over; the rest are the
        // same bug waiting for a caller.
        let unbound = unboundNames(inIR: try generateIR(Self.probe))
        #expect(unbound.contains(key), "\(key) is never unbound in compiled mode")
    }

    @Test("The query modifiers that were already cleared stay cleared",
          arguments: ["_where_field_", "_where_op_", "_where_value_", "_where_tree_",
                      "_by_pattern_", "_by_flags_", "_by_field_", "_by_var_",
                      "_by_order_", "_matching_", "_recursive_",
                      "_aggregation_type_", "_aggregation_field_", "_default_value_"])
    func previouslyClearedKeyStillCleared(key: String) throws {
        // Moving the list behind a shared constant must not drop anything the
        // hand-written list already had — each of these was added by its own
        // bug report.
        let unbound = unboundNames(inIR: try generateIR(Self.probe))
        #expect(unbound.contains(key), "\(key) regressed out of the unbind list")
    }
}

#endif
