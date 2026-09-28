// ============================================================
// AROStatementWalkTests.swift
// AROParser - The one statement walk, and what adopting it fixed
// GitLab #723
// ============================================================
//
// `AROStatementWalk` exists so that "which statements are inside this feature
// set?" has one answer. GitLab #660 gave the three `aro check` validators
// that answer; GitLab #723 found seven more hand-written walks with seven
// different coverages. The suites below pin the walk itself, and then pin the
// behaviour each adoption changed — every one of them a construct the private
// recursion never entered.

import Testing
import Foundation
@testable import AROParser

@Suite("Statement walk (GitLab #723)")
struct AROStatementWalkTests {

    /// One feature set holding every construct that can contain statements.
    private static let nested = """
    (Application-Start: Walk) {
        Create the <n> with 1.
        when <n> = 1 {
            Compute the <in-when: uppercase> from "a".
        }
        match <n> {
            case 1 {
                Compute the <in-case: uppercase> from "b".
            }
            otherwise {
                Compute the <in-otherwise: uppercase> from "c".
            }
        }
        while <n> < 1 {
            Compute the <in-while: uppercase> from "d".
        }
        for <i> from 1 to 2 {
            Compute the <in-range: uppercase> from "e".
        }
        for each <item> in [1, 2] {
            Compute the <in-foreach: uppercase> from "f".
        }
        Extract the <text> from "hello"
          |> Compute the <in-pipeline: uppercase> from the <text>.
        Publish as <exported> <n>.
        Return an <OK: status> for the <startup>.
    }
    """

    private func statements(_ source: String) -> [Statement] {
        let result = Compiler().compile(source)
        return result.program.featureSets.first?.statements ?? []
    }

    @Test("flatten reaches every nested body, at any depth")
    func flattenReachesEveryBody() {
        let bound = Set(AROStatementWalk.flatten(statements(Self.nested)).map(\.result.base))

        #expect(bound.isSuperset(of: [
            "in-when", "in-case", "in-otherwise",
            "in-while", "in-range", "in-foreach", "in-pipeline",
        ]))
    }

    @Test("flattenAll yields the containers too, each before what it holds")
    func flattenAllIsPreOrder() {
        let all = AROStatementWalk.flattenAll(statements(Self.nested))

        // A consumer that has something to say about a container — the LLVM
        // generator about a range loop's variable, the body-materialization
        // pass about a match's subject — needs the node itself, which is why
        // this shape exists alongside `flatten`.
        #expect(all.contains { $0 is WhenStatement })
        #expect(all.contains { $0 is MatchStatement })
        #expect(all.contains { $0 is WhileLoop })
        #expect(all.contains { $0 is RangeLoop })
        #expect(all.contains { $0 is ForEachLoop })
        #expect(all.contains { $0 is PipelineStatement })
        #expect(all.contains { $0 is PublishStatement })

        let whenIndex = all.firstIndex { $0 is WhenStatement }
        let insideIndex = all.firstIndex { $0.asAROStatement?.result.base == "in-when" }
        #expect(whenIndex != nil && insideIndex != nil)
        #expect(whenIndex! < insideIndex!)
    }

    @Test("flatten is flattenAll's actions, in the same order")
    func flattenAgreesWithFlattenAll() {
        let source = statements(Self.nested)
        let fromAll = AROStatementWalk.flattenAll(source).compactMap(\.asAROStatement).map(\.result.base)

        #expect(AROStatementWalk.flatten(source).map(\.result.base) == fromAll)
    }
}

@Suite("Analyses see inside every block (GitLab #723)")
struct NestedBlockAnalysisTests {

    private func diagnostics(_ source: String) -> [Diagnostic] {
        Compiler().compile(source).diagnostics
    }

    @Test("An unknown user-defined action is caught inside a when block")
    func unknownActionInsideWhenBlock() {
        // `UserActionAnalyzer.visit` entered loops and match cases but not a
        // `when` block, so this call reached the runtime instead of the
        // check.
        let source = """
        (Application-Start: X) {
            Create the <n> with 1.
            when <n> = 1 {
                Application.NoSuchAction the <r> with { a: 1 }.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let errors = diagnostics(source).filter { $0.severity == .error }
        #expect(errors.contains { $0.message.contains("Application.NoSuchAction") })
    }

    @Test("An unknown user-defined action is caught in a match's otherwise")
    func unknownActionInsideOtherwise() {
        let source = """
        (Application-Start: X) {
            Create the <n> with 1.
            match <n> {
                case 2 {
                    Log "two" to the <console>.
                }
                otherwise {
                    Application.AlsoMissing the <r> with { a: 1 }.
                }
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let errors = diagnostics(source).filter { $0.severity == .error }
        #expect(errors.contains { $0.message.contains("Application.AlsoMissing") })
    }

    @Test("A body read inside a when block is a read")
    func bodyReadInsideWhenBlockMaterializes() {
        // The taint walk never entered the block, so this route was published
        // as streaming and its limit was never applied — the conservative
        // direction is the other one.
        let source = """
        (uploadDocument: Files) {
            Extract the <upload> from the <request: body>.
            Create the <ok> with true.
            when <ok> = true {
                Compute the <shouted: uppercase> from <upload>.
                Log <shouted> to the <console>.
            }
            Return a <Created: status> for the <ok>.
        }
        """
        let summaries = BodyMaterializationAnalyzer.analyze(Compiler().compile(source).program.featureSets)
        #expect(summaries["uploadDocument"]?.materializes == true)
    }

    @Test("A body only moved inside a when block still streams")
    func bodyMovedInsideWhenBlockStreams() {
        // The control for the test above: descending into the block must not
        // make everything inside it count as a read.
        let source = """
        (uploadDocument: Files) {
            Extract the <upload> from the <request: body>.
            Create the <ok> with true.
            when <ok> = true {
                Write the <upload> to the <file: "out.bin">.
            }
            Return a <Created: status> for the <ok>.
        }
        """
        let summaries = BodyMaterializationAnalyzer.analyze(Compiler().compile(source).program.featureSets)
        #expect(summaries["uploadDocument"]?.materializes == false)
    }

    @Test("A when block that asks about the body reads it")
    func whenBlockConditionOnBodyMaterializes() {
        // A block's condition is the same question the statement-level `when`
        // suffix asks, and that has always counted as a read. It could not be
        // asked before, because the walk never reached the block.
        let source = """
        (uploadDocument: Files) {
            Extract the <upload> from the <request: body>.
            when <upload> is not empty {
                Write the <upload> to the <file: "out.bin">.
            }
            Return a <Created: status> for the <upload>.
        }
        """
        let summaries = BodyMaterializationAnalyzer.analyze(Compiler().compile(source).program.featureSets)
        #expect(summaries["uploadDocument"]?.materializes == true)
    }

    @Test("A misspelled status name is caught inside a when block")
    func statusNameInsideWhenBlock() {
        // `ResponseStatusValidator` carried a fourth copy of the walk that
        // GitLab #660 consolidated, so this status kept its silent 200.
        let source = """
        (createNote: Notes API) {
            Create the <n> with 1.
            when <n> = 1 {
                Return a <TooManyReqests: status> for the <n>.
            }
            Return an <OK: status> for the <n>.
        }
        """
        let warnings = diagnostics(source).filter { $0.severity == .warning }
        #expect(warnings.contains { $0.message.contains("TooManyReqests") })
    }

    @Test("An Emit inside a while loop is an emitted event")
    func emitInsideWhileLoopIsFound() {
        // Both emitted-event collectors stopped at a while loop, while the
        // cached walk the same warning normally runs off did not — so whether
        // this event existed depended on which caller asked.
        let source = """
        (Application-Start: X) {
            Create the <n> with 1.
            while <n> < 1 {
                Emit a <LoopEvent: event> with <n>.
            }
            Return an <OK: status> for the <startup>.
        }
        """
        let statements = Compiler().compile(source).program.featureSets[0].statements
        let emitted = EventAnalyzer.findEmittedEventsWithLocations(in: statements)

        #expect(emitted.map(\.0) == ["LoopEvent"])
    }

    @Test("An Emit inside a while loop is an edge in the event graph")
    func emitInsideWhileLoopIsAnEdge() throws {
        let source = """
        (Handle Alpha: EventAlpha Handler) {
            Create the <n> with 1.
            while <n> < 1 {
                Emit the <EventBeta: event> for the <trigger>.
            }
            Return an <OK: status> for the <handler>.
        }
        """
        let diagnostics = DiagnosticCollector()
        let analyzed = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)
        let graph = EventChainAnalyzer().buildEventGraph(in: analyzed.featureSets)

        #expect(graph.graph["EventAlpha"]?.contains("EventBeta") == true)
    }
}
