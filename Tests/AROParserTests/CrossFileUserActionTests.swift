// ============================================================
// CrossFileUserActionTests.swift
// AROParser - `Application.<Name>` across file boundaries (GitLab #587)
// ============================================================
//
// ARO-0005 and ARO-0081 §2 both say an application's feature sets are visible
// to each other with no imports, "regardless of file". The user-action registry
// was built per compiled file, so a call answered by a declaration one file
// over failed — under a hint that denied any action was declared at all.

import Testing
import Foundation
@testable import AROParser

@Suite("Cross-file user-defined actions (GitLab #587)")
struct CrossFileUserActionTests {

    /// Compile an application the way `aro check` / `aro run` / `aro build` do:
    /// scan every source for its declarations first, then compile file by file
    /// with that union in hand.
    private func compileApplication(_ sources: [String]) -> [CompilationResult] {
        let declared = UserActionRegistry.declared(inSources: sources)
        return sources.map { Compiler().compile($0, declaredUserActions: declared) }
    }

    private func errors(_ results: [CompilationResult]) -> [Diagnostic] {
        results.flatMap { $0.diagnostics.filter { $0.severity == .error } }
    }

    // The issue's own two files.
    private let callerFile = """
    (Application-Start: X) {
        Application.Doubled the <r> from 21.
        Extract the <v> from the <r: value>.
        Log <v> to the <console>.
        Return an <OK: status> for the <x>.
    }
    """

    private let actionFile = """
    (Doubled: Action takes <number>) {
        Extract the <n> from the <input: number>.
        Compute the <out> from <n> * 2.
        Return an <OK: status> with { value: <out> }.
    }
    """

    // MARK: - Resolution

    @Test("The issue's repro compiles: main.aro calls an action declared in other.aro")
    func callResolvesIntoSiblingFile() {
        let results = compileApplication([callerFile, actionFile])
        #expect(errors(results).isEmpty,
                "unexpected errors: \(errors(results).map(\.message))")
    }

    @Test("File order does not matter — the declaring file may be compiled first")
    func callResolvesRegardlessOfCompileOrder() {
        let results = compileApplication([actionFile, callerFile])
        #expect(errors(results).isEmpty,
                "unexpected errors: \(errors(results).map(\.message))")
    }

    @Test("Reverse direction: the declaring file calls an action in the other file")
    func declaringFileCallsIntoTheOtherFile() {
        let inner = """
        (Application-Start: X) {
            Application.Outer the <r> from 5.
            Return an <OK: status> for the <x>.
        }
        (Inner: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Compute the <out> from <n> + 1.
            Return an <OK: status> with { value: <out> }.
        }
        """
        let outer = """
        (Outer: Action takes <number>) {
            Extract the <n> from the <input: number>.
            Application.Inner the <i> from <n>.
            Extract the <v> from the <i: value>.
            Return an <OK: status> with { value: <v> }.
        }
        """
        let results = compileApplication([inner, outer])
        #expect(errors(results).isEmpty,
                "unexpected errors: \(errors(results).map(\.message))")
    }

    @Test("Mutual recursion across two files compiles, with no false base-case warning")
    func mutualRecursionAcrossFiles() {
        let evenFile = """
        (IsEven: Action takes <n>) {
            Extract the <n> from the <input: n>.
            Return an <OK: status> with { answer: "yes" } when <n> = 0.
            Compute the <next> from <n> - 1.
            Application.IsOdd the <sub> from <next>.
            Extract the <a> from the <sub: answer>.
            Return an <OK: status> with { answer: <a> }.
        }
        """
        let oddFile = """
        (IsOdd: Action takes <n>) {
            Extract the <n> from the <input: n>.
            Return an <OK: status> with { answer: "no" } when <n> = 0.
            Compute the <next> from <n> - 1.
            Application.IsEven the <sub> from <next>.
            Extract the <a> from the <sub: answer>.
            Return an <OK: status> with { answer: <a> }.
        }
        """
        let results = compileApplication([evenFile, oddFile])
        #expect(errors(results).isEmpty,
                "unexpected errors: \(errors(results).map(\.message))")

        let recursionWarnings = results
            .flatMap(\.diagnostics)
            .filter { $0.message.contains("no base case") }
        #expect(recursionWarnings.isEmpty,
                "guarded base cases must not be reported: \(recursionWarnings.map(\.message))")
    }

    // MARK: - Diagnostics

    @Test("A name declared nowhere still errors, and the hint names the near miss")
    func unknownNameStillErrors() {
        let typo = """
        (Application-Start: X) {
            Application.Doubld the <r> from 21.
            Return an <OK: status> for the <x>.
        }
        """
        let results = compileApplication([typo, actionFile])
        let errs = errors(results)
        #expect(errs.count == 1)
        #expect(errs.first?.message == "Unknown user-defined action 'Application.Doubld'")

        let hints = errs.first?.hints ?? []
        #expect(hints.contains("Did you mean 'Application.Doubled'?"))
        #expect(hints.contains("Known user-defined actions: Application.Doubled"))
        // The lie the issue is about.
        #expect(!hints.contains { $0.contains("No user-defined actions are declared") })
    }

    @Test("'No user-defined actions are declared in this application' is only said when true")
    func emptyApplicationHintIsTruthful() {
        let lonely = """
        (Application-Start: X) {
            Application.Nope the <r> with { a: 1 }.
            Return an <OK: status> for the <x>.
        }
        """
        let results = compileApplication([lonely])
        let errs = errors(results)
        #expect(errs.count == 1)
        let hints = errs.first?.hints ?? []
        #expect(hints.contains("No user-defined actions are declared in this application"))
        #expect(hints.contains("Declare one with `(MyAction: Action) { ... }`"))
    }

    @Test("A single file analysed alone says so instead of speaking for the application")
    func singleFileHintNamesItsOwnHorizon() {
        // No `declaredUserActions`: the LSP, the REPL and `aro check one.aro`.
        let result = Compiler().compile(callerFile)
        let errs = result.diagnostics.filter { $0.severity == .error }
        #expect(errs.count == 1)
        let hints = errs.first?.hints ?? []
        #expect(hints.contains("No user-defined actions are declared in this file, and only this file was analysed"))
        #expect(hints.contains { $0.contains("(Doubled: Action)") })
        #expect(!hints.contains("No user-defined actions are declared in this application"))
    }

    // MARK: - Single-file behaviour is unchanged

    @Test("An action and its caller in one file still compile with no application context")
    func singleFileCallStillResolves() {
        let source = callerFile + "\n" + actionFile
        let result = Compiler().compile(source)
        let errs = result.diagnostics.filter { $0.severity == .error }
        #expect(errs.isEmpty, "unexpected errors: \(errs.map(\.message))")
    }

    @Test("Duplicate names inside one file are still reported exactly once")
    func inFileDuplicateReportedOnce() {
        let doubled = actionFile + "\n" + actionFile
        let results = compileApplication([doubled])
        let duplicates = errors(results).filter { $0.message.contains("Duplicate user-defined action") }
        #expect(duplicates.count == 1)
    }

    @Test("A lone declaration is not mistaken for a duplicate of the application-wide copy of itself")
    func applicationScopeDoesNotSelfDuplicate() {
        let results = compileApplication([callerFile, actionFile])
        let duplicates = errors(results).filter { $0.message.contains("Duplicate user-defined action") }
        #expect(duplicates.isEmpty)
    }

    // MARK: - Registry mechanics

    @Test("declared(inSources:) finds actions and keeps the takes clause")
    func declaredDiscoversTakesClause() {
        let registry = UserActionRegistry.declared(inSources: [callerFile, actionFile])
        #expect(registry.allNames == ["Doubled"])
        #expect(registry.info(for: "Doubled")?.takesField == "number")
    }

    @Test("A source that does not parse contributes nothing instead of failing the scan")
    func unparsableSourceIsSkipped() {
        let broken = "(Broken: Action) { this is not ARO ((("
        let registry = UserActionRegistry.declared(inSources: [broken, actionFile])
        #expect(registry.allNames == ["Doubled"])
    }

    @Test("merging keeps the local entry when both sides declare a name")
    func mergingPrefersLocal() {
        let local = UserActionRegistry.declared(inSources: [actionFile])
        let external = UserActionRegistry.declared(inSources: ["""
        (Doubled: Action) {
            Return an <OK: status> with { value: 0 }.
        }
        """])
        let merged = local.merging(external)
        #expect(merged.info(for: "Doubled")?.takesField == "number")
    }
}
