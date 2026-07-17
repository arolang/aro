// ============================================================
// DataFlowVisitorTests.swift
// ARO Parser - DataFlowAnalyzer visitor-dispatch equivalence (#338)
// ============================================================

import Testing
@testable import AROParser

@Suite("DataFlow Visitor Dispatch")
struct DataFlowVisitorTests {

    private func analyzeFirst(_ source: String) throws -> AnalyzedFeatureSet {
        let program = try Parser.parse(source)
        let analyzer = DataFlowAnalyzer(diagnostics: DiagnosticCollector())
        return analyzer.analyzeFeatureSet(program.featureSets[0])
    }

    /// Nested match + for-each + publish: a program that drives every branch
    /// of the statement visitor, plus recursion through match cases and
    /// for-each bodies. A dispatch mistake (a node routed to the wrong
    /// `visit`) would change which symbols get defined / exported.
    @Test("Nested match + for-each + publish defines and exports expected symbols")
    func nestedControlFlow() throws {
        let source = """
        (Process Orders: Fulfillment) {
            Extract the <orders> from the <request: body>.
            Create the <tier> with "gold".
            for each <order> in <orders> {
                Compute the <total> from <order>.
                match <tier> {
                    case "gold" {
                        Compute the <discount> from <total>.
                    }
                    otherwise {
                        Compute the <base-price> from <total>.
                    }
                }
            }
            Compute the <summary> from <orders>.
            Publish as <report> <summary>.
        }
        """

        let analyzed = try analyzeFirst(source)
        let names = Set(analyzed.symbolTable.symbols.keys)

        // Top-level and nested definitions are all recorded.
        #expect(names.contains("orders"))
        #expect(names.contains("total"))
        #expect(names.contains("discount"))
        #expect(names.contains("base-price"))
        #expect(names.contains("summary"))

        // Publish alias is exported and present as a published symbol.
        #expect(analyzed.exports.contains("report"))
        #expect(names.contains("report"))

        // Loop-local item variable is not leaked as a feature-set output.
        let allOutputs = analyzed.dataFlows.reduce(into: Set<String>()) {
            $0.formUnion($1.outputs)
        }
        #expect(!allOutputs.contains("order"))
    }

    /// While loop + break: exercises the WhileLoop and BreakStatement visit
    /// methods and the shared-scope (`inMutableScope`) recursion path.
    @Test("While loop body is analyzed and break is a no-op")
    func whileAndBreak() throws {
        let source = """
        (Poll: Worker) {
            Extract the <items> from the <request: body>.
            Compute the <count> from 3.
            while <count> > 0 {
                Compute the <count> from <count> - 1.
                break.
            }
            Return an <OK: status> with <count>.
        }
        """

        let analyzed = try analyzeFirst(source)
        let names = Set(analyzed.symbolTable.symbols.keys)
        #expect(names.contains("items"))
        #expect(names.contains("count"))
    }

    /// Expression-visitor equivalence: variables referenced inside a nested
    /// expression (grouped + binary) become dependencies.
    @Test("Expression variables surface as dependencies")
    func expressionDependencies() throws {
        let source = """
        (Compute Fee: Billing) {
            Compute the <fee> from (<base> + <rate>) * <qty>.
            Return an <OK: status> with <fee>.
        }
        """

        let analyzed = try analyzeFirst(source)
        #expect(analyzed.dependencies.contains("base"))
        #expect(analyzed.dependencies.contains("rate"))
        #expect(analyzed.dependencies.contains("qty"))
    }
}
