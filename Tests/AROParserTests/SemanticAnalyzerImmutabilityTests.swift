// ============================================================
// SemanticAnalyzerImmutabilityTests.swift
// ARO Parser Tests - Variable Immutability
// ============================================================

import Testing
@testable import AROParser

@Suite("Immutability Semantic Analysis")
struct SemanticAnalyzerImmutabilityTests {

    @Test("Detect duplicate binding in same feature set")
    func testDuplicateBindingError() throws {
        let source = """
        (Test: Feature) {
            <Make> the <value> with "first".
            <Make> the <value> with "second".
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count == 1)
        #expect(errors[0].message.contains("Cannot rebind variable 'value'"))
        #expect(errors[0].message.contains("variables are immutable"))
    }

    @Test("Allow framework variables to rebind")
    func testFrameworkVariableRebindAllowed() throws {
        let source = """
        (Test: Feature) {
            <Make> the <_internal> with "first".
            <Make> the <_internal> with "second".
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Loop variables can be used across iterations")
    func testLoopVariableUsage() throws {
        let source = """
        (Test: Feature) {
            <Create> the <items> with ["a", "b", "c"].
            for each <item> in <items> {
                <Log> <item> to the <console>.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Cannot rebind loop variable within iteration")
    func testLoopVariableImmutable() throws {
        let source = """
        (Test: Feature) {
            <Create> the <items> with [1, 2, 3].
            for each <item> in <items> {
                <Compute> the <item> from <item> + 1.
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count >= 1)
        #expect(errors[0].message.contains("Cannot rebind variable 'item'"))
    }

    @Test("Match case variables are immutable")
    func testMatchVariablesImmutable() throws {
        let source = """
        (Test: Feature) {
            <Create> the <status> with "success".
            match <status> {
                case "success" {
                    <Create> the <status> with "done".
                }
                otherwise {
                    <Log> "default" to the <console>.
                }
            }
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count >= 1)
        #expect(errors[0].message.contains("Cannot rebind variable 'status'"))
    }

    @Test("Can create new variables from existing ones")
    func testCreateNewVariables() throws {
        let source = """
        (Test: Feature) {
            <Make> the <value> with 10.
            <Compute> the <value-incremented> from <value> + 5.
            <Compute> the <value-doubled> from <value-incremented> * 2.
            <Return> an <OK: status> with <value-doubled>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Multiple rebinding attempts are all reported")
    func testMultipleRebindingErrors() throws {
        let source = """
        (Test: Feature) {
            <Make> the <counter> with 0.
            <Compute> the <counter> from <counter> + 1.
            <Compute> the <counter> from <counter> + 1.
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count == 2)
        #expect(errors[0].message.contains("Cannot rebind variable 'counter'"))
        #expect(errors[1].message.contains("Cannot rebind variable 'counter'"))
    }

    @Test("Different variables can have same suffix")
    func testDifferentVariableSameSuffix() throws {
        let source = """
        (Test: Feature) {
            <Make> the <user-name> with "Alice".
            <Make> the <product-name> with "Widget".
            <Make> the <file-name> with "data.txt".
            <Return> an <OK: status> for the <test>.
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.isEmpty)
    }

    @Test("Hints suggest creating new variable")
    func testErrorHintsProvided() throws {
        let source = """
        (Test: Feature) {
            <Make> the <value> with "first".
            <Make> the <value> with "second".
        }
        """

        let compiler = Compiler()
        let result = compiler.compile(source)

        let errors = result.diagnostics.filter { $0.severity == .error }
        #expect(errors.count > 0)
        let error = errors[0]
        #expect(error.hints.count > 0)
        #expect(error.hints.contains(where: { $0.contains("Create a new variable") }))
        #expect(error.hints.contains(where: { $0.contains("value-updated") }))
    }
}
