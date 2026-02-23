// ============================================================
// VisitorPatternTests.swift
// ARO Parser - AST Visitor Pattern Tests (ARO-0061)
// ============================================================

import Testing
@testable import AROParser

// MARK: - Example Visitors

/// Counts all AST nodes
struct NodeCounterVisitor: ASTVisitor {
    typealias Result = Int

    func visit(_ node: Program) throws -> Int {
        var count = 1
        for imp in node.imports {
            count += try imp.accept(self)
        }
        for fs in node.featureSets {
            count += try fs.accept(self)
        }
        return count
    }

    func visit(_ node: ImportDeclaration) throws -> Int {
        1
    }

    func visit(_ node: FeatureSet) throws -> Int {
        var count = 1
        for stmt in node.statements {
            count += try stmt.accept(self)
        }
        return count
    }

    func visit(_ node: AROStatement) throws -> Int {
        1
    }

    func visit(_ node: PublishStatement) throws -> Int {
        1
    }

    func visit(_ node: RequireStatement) throws -> Int {
        1
    }

    func visit(_ node: MatchStatement) throws -> Int {
        var count = 1
        for caseClause in node.cases {
            for stmt in caseClause.body {
                count += try stmt.accept(self)
            }
        }
        if let otherwise = node.otherwise {
            for stmt in otherwise {
                count += try stmt.accept(self)
            }
        }
        return count
    }

    func visit(_ node: ForEachLoop) throws -> Int {
        var count = 1
        for stmt in node.body {
            count += try stmt.accept(self)
        }
        return count
    }

    func visit(_ node: PipelineStatement) throws -> Int {
        var count = 1
        for stmt in node.stages {
            count += try stmt.accept(self)
        }
        return count
    }

    func visit(_ node: LiteralExpression) throws -> Int {
        1
    }

    func visit(_ node: ArrayLiteralExpression) throws -> Int {
        var count = 1
        for elem in node.elements {
            count += try elem.accept(self)
        }
        return count
    }

    func visit(_ node: MapLiteralExpression) throws -> Int {
        var count = 1
        for entry in node.entries {
            count += try entry.value.accept(self)
        }
        return count
    }

    func visit(_ node: VariableRefExpression) throws -> Int {
        1
    }

    func visit(_ node: BinaryExpression) throws -> Int {
        1 + (try node.left.accept(self)) + (try node.right.accept(self))
    }

    func visit(_ node: UnaryExpression) throws -> Int {
        1 + (try node.operand.accept(self))
    }

    func visit(_ node: MemberAccessExpression) throws -> Int {
        1 + (try node.base.accept(self))
    }

    func visit(_ node: SubscriptExpression) throws -> Int {
        1 + (try node.base.accept(self)) + (try node.index.accept(self))
    }

    func visit(_ node: GroupedExpression) throws -> Int {
        1 + (try node.expression.accept(self))
    }

    func visit(_ node: ExistenceExpression) throws -> Int {
        1
    }

    func visit(_ node: TypeCheckExpression) throws -> Int {
        1
    }

    func visit(_ node: InterpolatedStringExpression) throws -> Int {
        1
    }
}

/// Collects all variable base names
struct VariableCollectorVisitor: ASTVisitor {
    typealias Result = Set<String>

    func visit(_ node: Program) throws -> Set<String> {
        var vars: Set<String> = []
        for fs in node.featureSets {
            vars.formUnion(try fs.accept(self))
        }
        return vars
    }

    func visit(_ node: ImportDeclaration) throws -> Set<String> {
        []
    }

    func visit(_ node: FeatureSet) throws -> Set<String> {
        var vars: Set<String> = []
        for stmt in node.statements {
            vars.formUnion(try stmt.accept(self))
        }
        return vars
    }

    func visit(_ node: AROStatement) throws -> Set<String> {
        [node.result.base, node.object.noun.base]
    }

    func visit(_ node: PublishStatement) throws -> Set<String> {
        [node.internalVariable]
    }

    func visit(_ node: RequireStatement) throws -> Set<String> {
        [node.variableName]
    }

    func visit(_ node: MatchStatement) throws -> Set<String> {
        var vars: Set<String> = [node.subject.base]
        for caseClause in node.cases {
            for stmt in caseClause.body {
                vars.formUnion(try stmt.accept(self))
            }
        }
        if let otherwise = node.otherwise {
            for stmt in otherwise {
                vars.formUnion(try stmt.accept(self))
            }
        }
        return vars
    }

    func visit(_ node: ForEachLoop) throws -> Set<String> {
        var vars: Set<String> = [node.itemVariable, node.collection.base]
        if let index = node.indexVariable {
            vars.insert(index)
        }
        for stmt in node.body {
            vars.formUnion(try stmt.accept(self))
        }
        return vars
    }

    func visit(_ node: PipelineStatement) throws -> Set<String> {
        var vars: Set<String> = []
        for stmt in node.stages {
            vars.formUnion(try stmt.accept(self))
        }
        return vars
    }

    func visit(_ node: LiteralExpression) throws -> Set<String> {
        []
    }

    func visit(_ node: ArrayLiteralExpression) throws -> Set<String> {
        var vars: Set<String> = []
        for elem in node.elements {
            vars.formUnion(try elem.accept(self))
        }
        return vars
    }

    func visit(_ node: MapLiteralExpression) throws -> Set<String> {
        var vars: Set<String> = []
        for entry in node.entries {
            vars.formUnion(try entry.value.accept(self))
        }
        return vars
    }

    func visit(_ node: VariableRefExpression) throws -> Set<String> {
        [node.noun.base]
    }

    func visit(_ node: BinaryExpression) throws -> Set<String> {
        var vars = try node.left.accept(self)
        vars.formUnion(try node.right.accept(self))
        return vars
    }

    func visit(_ node: UnaryExpression) throws -> Set<String> {
        try node.operand.accept(self)
    }

    func visit(_ node: MemberAccessExpression) throws -> Set<String> {
        try node.base.accept(self)
    }

    func visit(_ node: SubscriptExpression) throws -> Set<String> {
        var vars = try node.base.accept(self)
        vars.formUnion(try node.index.accept(self))
        return vars
    }

    func visit(_ node: GroupedExpression) throws -> Set<String> {
        try node.expression.accept(self)
    }

    func visit(_ node: ExistenceExpression) throws -> Set<String> {
        []  // Just checks existence, doesn't reference variable
    }

    func visit(_ node: TypeCheckExpression) throws -> Set<String> {
        []  // Just checks type, doesn't reference variable
    }

    func visit(_ node: InterpolatedStringExpression) throws -> Set<String> {
        []
    }
}

// MARK: - Test Suite

@Suite("Visitor Pattern Tests")
struct VisitorPatternTests {

    @Test("Node counter visitor counts all nodes")
    func nodeCounterTest() throws {
        let source = """
        (Test Feature: Simple) {
            Extract the <data> from the <source>.
            Return an <OK: status> for the <result>.
        }
        """

        let program = try Parser.parse(source)
        let visitor = NodeCounterVisitor()
        let count = try program.accept(visitor)

        // Program(1) + FeatureSet(1) + 2 AROStatements(2) = 4 nodes
        #expect(count == 4)
    }

    @Test("Variable collector finds all variables")
    func variableCollectorTest() throws {
        let source = """
        (Test Feature: Simple) {
            Extract the <data> from the <source>.
            Compute the <result> from the <data>.
            Return an <OK: status> for the <result>.
        }
        """

        let program = try Parser.parse(source)
        let visitor = VariableCollectorVisitor()
        let variables = try program.accept(visitor)

        // Should find: data, source, result (status may have qualifier OK)
        #expect(variables.contains("data"))
        #expect(variables.contains("source"))
        #expect(variables.contains("result"))
        #expect(variables.count >= 3)
    }

    @Test("Visitor handles for-each loops")
    func forEachLoopVisitorTest() throws {
        let source = """
        (Test: Loop) {
            For each <item> in <items> {
                Log <item> to the <console>.
            }
            Return an <OK: status> for the <processing>.
        }
        """

        let program = try Parser.parse(source)
        let varVisitor = VariableCollectorVisitor()
        let variables = try program.accept(varVisitor)

        #expect(variables.contains("item"))
        #expect(variables.contains("items"))
        #expect(variables.contains("console"))
        #expect(variables.contains("processing"))
    }

    @Test("Visitor traverses all nodes")
    func visitorTraversalTest() throws {
        let source = """
        (Test: Simple) {
            Extract the <data> from the <source>.
            Publish as <output> <data>.
        }
        """

        let program = try Parser.parse(source)
        let counter = NodeCounterVisitor()
        let count = try program.accept(counter)

        // Visitor should count at least Program + FeatureSet + statements
        #expect(count >= 3)
    }

    @Test("Empty program returns one node")
    func emptyProgramVisitorTest() throws {
        let source = ""

        let program = try Parser.parse(source)
        let visitor = NodeCounterVisitor()
        let count = try program.accept(visitor)

        // Just the Program node itself
        #expect(count == 1)
    }
}
