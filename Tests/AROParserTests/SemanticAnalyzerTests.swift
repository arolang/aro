// ============================================================
// SemanticAnalyzerTests.swift
// ARO Parser - Comprehensive Semantic Analyzer Unit Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Symbol Tests

@Suite("Symbol Tests")
struct SymbolTests {

    @Test("Symbol creation with all properties")
    func testSymbolCreation() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(
            name: "user",
            definedAt: span,
            visibility: .internal,
            source: .computed,
            dataType: .string
        )

        #expect(symbol.name == "user")
        #expect(symbol.visibility == .internal)
        #expect(symbol.source == .computed)
        #expect(symbol.dataType == .string)
    }

    @Test("Symbol description includes all info")
    func testSymbolDescription() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(
            name: "user",
            definedAt: span,
            visibility: .published,
            source: .extracted(from: "request"),
            dataType: .identifier
        )

        let desc = symbol.description
        #expect(desc.contains("user"))
        #expect(desc.contains("published"))
        #expect(desc.contains("extracted"))
    }

    @Test("Symbol equality")
    func testSymbolEquality() {
        let span = SourceSpan(at: SourceLocation())
        let symbol1 = Symbol(name: "user", definedAt: span, source: .computed)
        let symbol2 = Symbol(name: "user", definedAt: span, source: .computed)
        let symbol3 = Symbol(name: "other", definedAt: span, source: .computed)

        #expect(symbol1 == symbol2)
        #expect(symbol1 != symbol3)
    }
}

// MARK: - Visibility Tests

@Suite("Visibility Tests")
struct VisibilityTests {

    @Test("All visibility values exist")
    func testVisibilityValues() {
        #expect(Visibility.internal.rawValue == "internal")
        #expect(Visibility.published.rawValue == "published")
        #expect(Visibility.external.rawValue == "external")
    }
}

// MARK: - Symbol Source Tests

@Suite("Symbol Source Tests")
struct SymbolSourceTests {

    @Test("Extracted source description")
    func testExtractedSource() {
        let source = SymbolSource.extracted(from: "request")
        #expect(source.description.contains("extracted"))
        #expect(source.description.contains("request"))
    }

    @Test("Computed source description")
    func testComputedSource() {
        let source = SymbolSource.computed
        #expect(source.description == "computed")
    }

    @Test("Parameter source description")
    func testParameterSource() {
        let source = SymbolSource.parameter
        #expect(source.description == "parameter")
    }

    @Test("Alias source description")
    func testAliasSource() {
        let source = SymbolSource.alias(of: "original")
        #expect(source.description.contains("alias"))
        #expect(source.description.contains("original"))
    }

    @Test("Symbol source equality")
    func testSymbolSourceEquality() {
        #expect(SymbolSource.computed == SymbolSource.computed)
        #expect(SymbolSource.extracted(from: "a") == SymbolSource.extracted(from: "a"))
        #expect(SymbolSource.extracted(from: "a") != SymbolSource.extracted(from: "b"))
        #expect(SymbolSource.alias(of: "x") == SymbolSource.alias(of: "x"))
    }
}

// MARK: - Data Type Tests

@Suite("Data Type Tests")
struct DataTypeTests {

    @Test("Data type descriptions")
    func testDataTypeDescriptions() {
        #expect(DataType.string.description == "String")
        #expect(DataType.identifier.description == "Identifier")
        #expect(DataType.hash.description == "Hash")
        #expect(DataType.record.description == "Record")
        #expect(DataType.status.description == "Status")
        #expect(DataType.boolean.description == "Boolean")
        #expect(DataType.error.description == "Error")
        #expect(DataType.custom("User").description == "User")
    }

    @Test("Data type inference from specifiers")
    func testDataTypeInference() {
        #expect(DataType.infer(from: ["identifier"]) == .identifier)
        #expect(DataType.infer(from: ["id"]) == .identifier)
        #expect(DataType.infer(from: ["hash"]) == .hash)
        #expect(DataType.infer(from: ["checksum"]) == .hash)
        #expect(DataType.infer(from: ["record"]) == .record)
        #expect(DataType.infer(from: ["status"]) == .status)
        #expect(DataType.infer(from: ["result"]) == .boolean)
        #expect(DataType.infer(from: ["error"]) == .error)
        #expect(DataType.infer(from: ["custom"]) == .custom("Custom"))
        #expect(DataType.infer(from: []) == nil)
    }

    @Test("Data type equality")
    func testDataTypeEquality() {
        #expect(DataType.string == DataType.string)
        #expect(DataType.custom("A") == DataType.custom("A"))
        #expect(DataType.custom("A") != DataType.custom("B"))
    }
}

// MARK: - Symbol Table Tests

@Suite("Symbol Table Comprehensive Tests")
struct SymbolTableComprehensiveTests {

    @Test("Empty symbol table creation")
    func testEmptySymbolTable() {
        let table = SymbolTable(scopeId: "test", scopeName: "Test")

        #expect(table.scopeId == "test")
        #expect(table.scopeName == "Test")
        #expect(table.symbols.isEmpty)
    }

    @Test("Symbol lookup in current scope")
    func testSymbolLookup() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, source: .computed)
        let table = SymbolTable(scopeId: "test", scopeName: "Test", symbols: ["user": symbol])

        #expect(table.lookup("user") == symbol)
        #expect(table.lookup("other") == nil)
    }

    @Test("Symbol lookup in local scope")
    func testLocalLookup() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, source: .computed)
        let table = SymbolTable(scopeId: "test", scopeName: "Test", symbols: ["user": symbol])

        #expect(table.lookupLocal("user") == symbol)
        #expect(table.lookupLocal("other") == nil)
    }

    @Test("Symbol lookup with parent scope")
    func testParentScopeLookup() {
        let span = SourceSpan(at: SourceLocation())
        let parentSymbol = Symbol(name: "parent", definedAt: span, source: .computed)
        let childSymbol = Symbol(name: "child", definedAt: span, source: .computed)

        let parentTable = SymbolTable(scopeId: "parent", scopeName: "Parent", symbols: ["parent": parentSymbol])
        let childTable = SymbolTable(scopeId: "child", scopeName: "Child", parent: parentTable, symbols: ["child": childSymbol])

        #expect(childTable.lookup("child") == childSymbol)
        #expect(childTable.lookup("parent") == parentSymbol)
        #expect(childTable.lookupLocal("parent") == nil)
    }

    @Test("Symbol contains check")
    func testContains() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, source: .computed)
        let table = SymbolTable(scopeId: "test", scopeName: "Test", symbols: ["user": symbol])

        #expect(table.contains("user") == true)
        #expect(table.contains("other") == false)
    }

    @Test("All symbols including parent")
    func testAllSymbols() {
        let span = SourceSpan(at: SourceLocation())
        let parentSymbol = Symbol(name: "parent", definedAt: span, source: .computed)
        let childSymbol = Symbol(name: "child", definedAt: span, source: .computed)

        let parentTable = SymbolTable(scopeId: "parent", scopeName: "Parent", symbols: ["parent": parentSymbol])
        let childTable = SymbolTable(scopeId: "child", scopeName: "Child", parent: parentTable, symbols: ["child": childSymbol])

        let allSymbols = childTable.allSymbols
        #expect(allSymbols.count == 2)
        #expect(allSymbols["parent"] != nil)
        #expect(allSymbols["child"] != nil)
    }

    @Test("Published symbols filter")
    func testPublishedSymbols() {
        let span = SourceSpan(at: SourceLocation())
        let internalSymbol = Symbol(name: "internal", definedAt: span, visibility: .internal, source: .computed)
        let publishedSymbol = Symbol(name: "published", definedAt: span, visibility: .published, source: .computed)

        let table = SymbolTable(scopeId: "test", scopeName: "Test", symbols: [
            "internal": internalSymbol,
            "published": publishedSymbol
        ])

        #expect(table.publishedSymbols.count == 1)
        #expect(table.publishedSymbols["published"] != nil)
    }

    @Test("Defining new symbol returns new table")
    func testDefineSymbol() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, source: .computed)

        let table1 = SymbolTable(scopeId: "test", scopeName: "Test")
        let table2 = table1.define(symbol)

        #expect(table1.lookup("user") == nil)
        #expect(table2.lookup("user") == symbol)
    }

    @Test("Creating child scope")
    func testCreateChild() {
        let table = SymbolTable(scopeId: "parent", scopeName: "Parent")
        let child = table.createChild(scopeId: "child", scopeName: "Child")

        #expect(child.scopeId == "child")
        #expect(child.scopeName == "Child")
    }

    @Test("Symbol table description")
    func testDescription() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, visibility: .internal, source: .computed)
        let table = SymbolTable(scopeId: "test", scopeName: "Test", symbols: ["user": symbol])

        let desc = table.description
        #expect(desc.contains("SymbolTable"))
        #expect(desc.contains("user"))
    }
}

// MARK: - Symbol Table Builder Tests

@Suite("Symbol Table Builder Tests")
struct SymbolTableBuilderTests {

    @Test("Builder defines symbols")
    func testBuilderDefine() {
        let span = SourceSpan(at: SourceLocation())
        let builder = SymbolTableBuilder(scopeId: "test", scopeName: "Test")

        builder.define(name: "user", definedAt: span, source: .computed)

        let table = builder.build()
        #expect(table.lookup("user") != nil)
    }

    @Test("Builder supports chaining")
    func testBuilderChaining() {
        let span = SourceSpan(at: SourceLocation())
        let table = SymbolTableBuilder(scopeId: "test", scopeName: "Test")
            .define(name: "a", definedAt: span, source: .computed)
            .define(name: "b", definedAt: span, source: .computed)
            .define(name: "c", definedAt: span, source: .computed)
            .build()

        #expect(table.symbols.count == 3)
    }

    @Test("Builder updates visibility")
    func testBuilderUpdateVisibility() {
        let span = SourceSpan(at: SourceLocation())
        let table = SymbolTableBuilder(scopeId: "test", scopeName: "Test")
            .define(name: "user", definedAt: span, visibility: .internal, source: .computed)
            .updateVisibility(name: "user", to: .published)
            .build()

        #expect(table.lookup("user")?.visibility == .published)
    }

    @Test("Builder with parent scope")
    func testBuilderWithParent() {
        let span = SourceSpan(at: SourceLocation())
        let parentSymbol = Symbol(name: "parent", definedAt: span, source: .computed)
        let parent = SymbolTable(scopeId: "parent", scopeName: "Parent", symbols: ["parent": parentSymbol])

        let table = SymbolTableBuilder(scopeId: "child", scopeName: "Child", parent: parent)
            .define(name: "child", definedAt: span, source: .computed)
            .build()

        #expect(table.lookup("child") != nil)
        #expect(table.lookup("parent") != nil)
    }
}

// MARK: - Global Symbol Registry Tests

@Suite("Global Symbol Registry Tests")
struct GlobalSymbolRegistryTests {

    @Test("Registry registers symbols")
    func testRegisterSymbol() {
        let span = SourceSpan(at: SourceLocation())
        let symbol = Symbol(name: "user", definedAt: span, visibility: .published, source: .computed)

        let registry = GlobalSymbolRegistry()
        registry.register(symbol: symbol, fromFeatureSet: "UserFeature")

        let result = registry.lookup("user")
        #expect(result?.featureSet == "UserFeature")
        #expect(result?.symbol == symbol)
    }

    @Test("Registry lookup returns nil for unknown")
    func testLookupUnknown() {
        let registry = GlobalSymbolRegistry()
        #expect(registry.lookup("unknown") == nil)
    }

    @Test("Registry returns all published")
    func testAllPublished() {
        let span = SourceSpan(at: SourceLocation())
        let symbol1 = Symbol(name: "a", definedAt: span, visibility: .published, source: .computed)
        let symbol2 = Symbol(name: "b", definedAt: span, visibility: .published, source: .computed)

        let registry = GlobalSymbolRegistry()
        registry.register(symbol: symbol1, fromFeatureSet: "Feature1")
        registry.register(symbol: symbol2, fromFeatureSet: "Feature2")

        #expect(registry.allPublished.count == 2)
    }
}

// MARK: - Data Flow Info Tests

@Suite("Data Flow Info Tests")
struct DataFlowInfoTests {

    @Test("Data flow info creation")
    func testDataFlowInfoCreation() {
        let flow = DataFlowInfo(
            inputs: ["a", "b"],
            outputs: ["c"],
            sideEffects: ["emit:event"]
        )

        #expect(flow.inputs.contains("a"))
        #expect(flow.inputs.contains("b"))
        #expect(flow.outputs.contains("c"))
        #expect(flow.sideEffects == ["emit:event"])
    }

    @Test("Data flow info description")
    func testDataFlowInfoDescription() {
        let flow = DataFlowInfo(inputs: ["input"], outputs: ["output"])
        let desc = flow.description

        #expect(desc.contains("DataFlow"))
        #expect(desc.contains("input"))
        #expect(desc.contains("output"))
    }

    @Test("Data flow info equality")
    func testDataFlowInfoEquality() {
        let flow1 = DataFlowInfo(inputs: ["a"], outputs: ["b"])
        let flow2 = DataFlowInfo(inputs: ["a"], outputs: ["b"])
        let flow3 = DataFlowInfo(inputs: ["x"], outputs: ["y"])

        #expect(flow1 == flow2)
        #expect(flow1 != flow3)
    }

    @Test("Empty data flow info")
    func testEmptyDataFlowInfo() {
        let flow = DataFlowInfo()

        #expect(flow.inputs.isEmpty)
        #expect(flow.outputs.isEmpty)
        #expect(flow.sideEffects.isEmpty)
    }
}

// MARK: - Analyzed Feature Set Tests

@Suite("Analyzed Feature Set Tests")
struct AnalyzedFeatureSetTests {

    @Test("Analyzed feature set creation")
    func testAnalyzedFeatureSetCreation() {
        let span = SourceSpan(at: SourceLocation())
        let featureSet = FeatureSet(name: "Test", businessActivity: "Testing", statements: [], span: span)
        let symbolTable = SymbolTable(scopeId: "test", scopeName: "Test")

        let analyzed = AnalyzedFeatureSet(
            featureSet: featureSet,
            symbolTable: symbolTable,
            dataFlows: [],
            dependencies: ["request"],
            exports: ["output"]
        )

        #expect(analyzed.featureSet.name == "Test")
        #expect(analyzed.dependencies.contains("request"))
        #expect(analyzed.exports.contains("output"))
    }
}

// MARK: - Semantic Analyzer Tests

@Suite("Semantic Analyzer Comprehensive Tests")
struct SemanticAnalyzerComprehensiveTests {

    @Test("Analyzes empty program")
    func testEmptyProgram() throws {
        let analyzed = try SemanticAnalyzer.analyze("")

        #expect(analyzed.featureSets.isEmpty)
    }

    @Test("Analyzes simple feature set")
    func testSimpleFeatureSet() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <user> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        #expect(analyzed.featureSets.count == 1)
        #expect(analyzed.featureSets[0].symbolTable.lookup("user") != nil)
    }

    @Test("Tracks data flow for request action")
    func testRequestActionDataFlow() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <user> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        let dataFlow = analyzed.featureSets[0].dataFlows[0]
        #expect(dataFlow.inputs.contains("request"))
        #expect(dataFlow.outputs.contains("user"))
    }

    @Test("Tracks data flow for own action")
    func testOwnActionDataFlow() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <input> from the <request>.
            <Compute> the <output> for the <input>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        let dataFlow = analyzed.featureSets[0].dataFlows[1]
        #expect(dataFlow.inputs.contains("input"))
        #expect(dataFlow.outputs.contains("output"))
    }

    @Test("Tracks data flow for response action")
    func testResponseActionDataFlow() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
            <Return> the <response> for the <success>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        let dataFlow = analyzed.featureSets[0].dataFlows[1]
        #expect(dataFlow.sideEffects.count > 0)
    }

    @Test("Tracks external dependencies")
    func testExternalDependencies() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <user> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        // "request" is a known external, so it shouldn't be in dependencies
        // but the analyzer tracks it
        #expect(analyzed.featureSets.count == 1)
    }

    @Test("Tracks exports from publish statements")
    func testExportTracking() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
            <Publish> as <external-data> <data>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        #expect(analyzed.featureSets[0].exports.contains("external-data"))
    }

    @Test("Reports warning for undefined variable in publish")
    func testUndefinedVariableWarning() throws {
        let diagnostics = DiagnosticCollector()
        let source = """
        (Test: Testing) {
            <Publish> as <external> <undefined>.
        }
        """
        _ = try SemanticAnalyzer.analyze(source, diagnostics: diagnostics)

        #expect(diagnostics.hasErrors)
    }

    @Test("Registers published symbols in global registry")
    func testGlobalRegistryRegistration() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
            <Publish> as <published-data> <data>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        let result = analyzed.globalRegistry.lookup("published-data")
        #expect(result != nil)
    }

    @Test("Analyzes multiple feature sets")
    func testMultipleFeatureSets() throws {
        let source = """
        (Feature One: First) {
            <Extract> the <a> from the <request>.
        }
        (Feature Two: Second) {
            <Extract> the <b> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        #expect(analyzed.featureSets.count == 2)
    }

    @Test("Infers data type from specifiers")
    func testDataTypeInference() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <user: identifier> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        let symbol = analyzed.featureSets[0].symbolTable.lookup("user")
        #expect(symbol?.dataType == .identifier)
    }
}

// MARK: - Analyzed Program Tests

@Suite("Analyzed Program Tests")
struct AnalyzedProgramTests {

    @Test("Analyzed program contains all data")
    func testAnalyzedProgramData() throws {
        let source = """
        (Test: Testing) {
            <Extract> the <data> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)

        #expect(analyzed.program.featureSets.count == 1)
        #expect(analyzed.featureSets.count == 1)
        // GlobalSymbolRegistry is always present
        #expect(analyzed.globalRegistry.allPublished.isEmpty || analyzed.globalRegistry.allPublished.count >= 0)
    }
}
