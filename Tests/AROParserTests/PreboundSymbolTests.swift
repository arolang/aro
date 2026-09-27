// ============================================================
// PreboundSymbolTests.swift
// AROParser — names bound outside the source being compiled
// GitLab #689
// ============================================================
//
// A REPL or notebook cell is compiled on its own, wrapped in a throwaway
// feature set, while the values it refers to live in the session. Reading such
// a name is only a warning — which is why every other statement worked across
// cells — but `Publish` *errors* on an undefined variable:
//
//     cell A: Compute the <w> from 3 + 3.      → ok
//     cell B: Publish as <sharedw> <w>.        → Cannot publish undefined
//                                                variable 'w'
//
// `Publish` is how ARO shares values between feature sets, and in a notebook it
// is precisely the cross-cell operation. It was the one place the session's
// bindings were not accounted for.

import Foundation
import Testing
@testable import AROParser

@Suite("Pre-bound symbols (#689)")
struct PreboundSymbolTests {

    private func compile(_ source: String, prebound: Set<String> = []) -> CompilationResult {
        Compiler().compile(
            "(_repl_temp_: Interactive) {\n\(source)\n}",
            preboundSymbols: prebound
        )
    }

    private func errors(_ result: CompilationResult) -> [String] {
        result.diagnostics.filter { $0.severity == .error }.map(\.message)
    }

    @Test("Publishing a name from an earlier cell compiles")
    func publishesAPreboundName() {
        let result = compile("Publish as <sharedw> <w>.", prebound: ["w"])
        #expect(errors(result).isEmpty, "unexpected errors: \(errors(result))")
    }

    @Test("Publishing a name nothing has bound is still an error")
    func publishingAnUnknownNameStillFails() {
        // The check is narrowed, not removed. A name that is in neither the
        // source nor the session is genuinely undefined.
        let result = compile("Publish as <bad> <never-bound>.", prebound: ["w"])
        #expect(errors(result).contains { $0.contains("Cannot publish undefined variable 'never-bound'") })
    }

    @Test("An ordinary compile is unchanged")
    func ordinaryCompileStillChecks() {
        // No pre-bound names is the default, and for a whole program a name
        // not defined in the source genuinely is not defined.
        let result = compile("Publish as <sharedw> <w>.")
        #expect(errors(result).contains { $0.contains("Cannot publish undefined variable 'w'") })
    }

    @Test("A name defined in the source needs no help")
    func sourceDefinedNameStillWorks() {
        let result = compile("""
            Compute the <w> from 3 + 3.
            Publish as <sharedw> <w>.
            """)
        #expect(errors(result).isEmpty, "unexpected errors: \(errors(result))")
    }

    @Test("Pre-binding does not define the name for anything else")
    func preboundDoesNotSuppressOtherChecks() {
        // It answers exactly one question — "could this have been bound
        // elsewhere?" — and does not become a general escape hatch.
        let result = compile("Publish as <sharedw> <w>.", prebound: ["w"])
        #expect(errors(result).isEmpty)
        // The alias is still recorded as this feature set's export.
        let fs = result.analyzedProgram.byName["_repl_temp_"]
        #expect(fs?.exports.contains("sharedw") == true)
    }
}
