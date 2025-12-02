// ============================================================
// AROParserTests.swift
// ARO Parser - Unit Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Lexer Tests

@Suite("Lexer Tests")
struct LexerTests {
    
    @Test("Tokenizes simple statement")
    func testSimpleStatement() throws {
        let source = "<Extract> the <user: identifier> from the <request: parameters>."
        let tokens = try Lexer.tokenize(source)
        
        #expect(tokens.count > 0)
        #expect(tokens.first?.kind == .leftAngle)
    }
    
    @Test("Tokenizes feature set header")
    func testFeatureSetHeader() throws {
        let source = "(User Auth: Security) { }"
        let tokens = try Lexer.tokenize(source)
        
        #expect(tokens.first?.kind == .leftParen)
        #expect(tokens.contains { $0.kind == .colon })
    }
    
    @Test("Recognizes articles")
    func testArticles() throws {
        let source = "a an the"
        let tokens = try Lexer.tokenize(source)
        
        let articles = tokens.filter { 
            if case .article = $0.kind { return true }
            return false
        }
        #expect(articles.count == 3)
    }
    
    @Test("Recognizes prepositions")
    func testPrepositions() throws {
        // Note: "for" is tokenized as a keyword (for iteration), not as a preposition
        // The parser handles "for" specially when expecting a preposition
        let source = "from against to into with via"
        let tokens = try Lexer.tokenize(source)

        let prepositions = tokens.filter {
            if case .preposition = $0.kind { return true }
            return false
        }
        #expect(prepositions.count == 6)
    }
    
    @Test("Skips block comments")
    func testBlockComments() throws {
        let source = "(* This is a comment *) <Extract>"
        let tokens = try Lexer.tokenize(source)
        
        #expect(tokens.first?.kind == .leftAngle)
    }
    
    @Test("Handles compound identifiers")
    func testCompoundIdentifiers() throws {
        let source = "<incoming-request>"
        let tokens = try Lexer.tokenize(source)
        
        let identifiers = tokens.filter { $0.kind.isIdentifier }
        #expect(identifiers.count == 2) // "incoming" and "request" as separate tokens
    }
}

// MARK: - Parser Tests

@Suite("Parser Tests")
struct ParserTests {
    
    @Test("Parses empty program")
    func testEmptyProgram() throws {
        let tokens = try Lexer.tokenize("")
        let program = try Parser(tokens: tokens).parse()
        
        #expect(program.featureSets.isEmpty)
    }
    
    @Test("Parses feature set")
    func testFeatureSet() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <data> from the <source>.
        }
        """
        let program = try Parser.parse(source)
        
        #expect(program.featureSets.count == 1)
        #expect(program.featureSets[0].name == "Test")
        #expect(program.featureSets[0].businessActivity == "Activity")
    }
    
    @Test("Parses ARO statement")
    func testAROStatement() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user: identifier> from the <request: parameters>.
        }
        """
        let program = try Parser.parse(source)
        
        let statement = program.featureSets[0].statements[0] as? AROStatement
        #expect(statement != nil)
        #expect(statement?.action.verb == "Extract")
        #expect(statement?.result.base == "user")
        #expect(statement?.result.specifiers == ["identifier"])
    }
    
    @Test("Parses publish statement")
    func testPublishStatement() throws {
        let source = """
        (Test: Activity) {
            <Publish> as <external-name> <internal-var>.
        }
        """
        let program = try Parser.parse(source)
        
        let statement = program.featureSets[0].statements[0] as? PublishStatement
        #expect(statement != nil)
        #expect(statement?.externalName == "external-name")
        #expect(statement?.internalVariable == "internal-var")
    }
    
    @Test("Parses multiple statements")
    func testMultipleStatements() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <a> from the <b>.
            <Compute> the <c> for the <d>.
            <Return> the <e> for the <f>.
        }
        """
        let program = try Parser.parse(source)
        
        #expect(program.featureSets[0].statements.count == 3)
    }
}

// MARK: - Semantic Analyzer Tests

@Suite("Semantic Analyzer Tests")
struct SemanticAnalyzerTests {
    
    @Test("Classifies action verbs")
    func testActionClassification() {
        #expect(ActionSemanticRole.classify(verb: "Extract") == .request)
        #expect(ActionSemanticRole.classify(verb: "Compute") == .own)
        #expect(ActionSemanticRole.classify(verb: "Return") == .response)
        #expect(ActionSemanticRole.classify(verb: "Publish") == .export)
    }
    
    @Test("Builds symbol table")
    func testSymbolTable() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user: identifier> from the <request>.
            <Compute> the <hash> for the <user>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)
        
        let symbolTable = analyzed.featureSets[0].symbolTable
        #expect(symbolTable.lookup("user") != nil)
        #expect(symbolTable.lookup("hash") != nil)
    }
    
    @Test("Tracks data flow")
    func testDataFlow() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user> from the <request>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)
        
        let dataFlow = analyzed.featureSets[0].dataFlows[0]
        #expect(dataFlow.inputs.contains("request"))
        #expect(dataFlow.outputs.contains("user"))
    }
    
    @Test("Tracks dependencies")
    func testDependencies() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user> from the <external-source>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)
        
        #expect(analyzed.featureSets[0].dependencies.contains("external-source"))
    }
    
    @Test("Handles publish correctly")
    func testPublishHandling() throws {
        let source = """
        (Test: Activity) {
            <Extract> the <user> from the <request>.
            <Publish> as <exported-user> <user>.
        }
        """
        let analyzed = try SemanticAnalyzer.analyze(source)
        
        #expect(analyzed.featureSets[0].exports.contains("exported-user"))
        
        let userSymbol = analyzed.featureSets[0].symbolTable.lookup("user")
        #expect(userSymbol?.visibility == .published)
    }
}

// MARK: - Symbol Table Tests

@Suite("Symbol Table Tests")
struct SymbolTableTests {
    
    @Test("Defines and looks up symbols")
    func testDefineAndLookup() {
        let builder = SymbolTableBuilder(scopeId: "test", scopeName: "Test")
        builder.define(
            name: "myVar",
            definedAt: SourceSpan(at: SourceLocation()),
            source: .computed
        )
        
        let table = builder.build()
        #expect(table.lookup("myVar") != nil)
        #expect(table.lookup("unknown") == nil)
    }
    
    @Test("Supports parent scope lookup")
    func testParentScope() {
        let parentBuilder = SymbolTableBuilder(scopeId: "parent", scopeName: "Parent")
        parentBuilder.define(
            name: "parentVar",
            definedAt: SourceSpan(at: SourceLocation()),
            source: .computed
        )
        let parentTable = parentBuilder.build()
        
        let childBuilder = SymbolTableBuilder(scopeId: "child", scopeName: "Child", parent: parentTable)
        childBuilder.define(
            name: "childVar",
            definedAt: SourceSpan(at: SourceLocation()),
            source: .computed
        )
        let childTable = childBuilder.build()
        
        #expect(childTable.lookup("childVar") != nil)
        #expect(childTable.lookup("parentVar") != nil)
        #expect(childTable.lookupLocal("parentVar") == nil)
    }
    
    @Test("Updates visibility")
    func testUpdateVisibility() {
        let builder = SymbolTableBuilder(scopeId: "test", scopeName: "Test")
        builder.define(
            name: "myVar",
            definedAt: SourceSpan(at: SourceLocation()),
            visibility: .internal,
            source: .computed
        )
        builder.updateVisibility(name: "myVar", to: .published)
        
        let table = builder.build()
        #expect(table.lookup("myVar")?.visibility == .published)
    }
}

// MARK: - Integration Tests

@Suite("Integration Tests")
struct IntegrationTests {
    
    @Test("Full compilation pipeline")
    func testFullPipeline() {
        // Note: "and" is a keyword, so we use "Security Access Control" instead
        let source = """
        (User Authentication: Security Access Control) {
            <Extract> the <user: identifier> from the <incoming-request: parameters>.
            <Parse> the <signed: checksum> from the <request: headers>.
            <Retrieve> the <user: record> from the <user: repository>.
            <Compute> the <password: hash> for the <user: credentials>.
            <Compare> the <signed: checksum> against the <computed: password-hash>.
            <Validate> the <authentication: result> for the <user: request>.
            <Return> an <OK: status> for the <valid: authentication>.
            <Publish> as <authenticated-user> <user>.
        }
        """

        let result = Compiler.compile(source)

        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 1)
        #expect(result.program.featureSets[0].statements.count == 8)
    }
    
    @Test("Multiple feature sets")
    func testMultipleFeatureSets() {
        let source = """
        (Auth: Security) {
            <Extract> the <user> from the <request>.
            <Publish> as <authenticated-user> <user>.
        }
        
        (Logging: Audit) {
            <Log> the <action> for the <authenticated-user>.
        }
        """
        
        let result = Compiler.compile(source)
        
        #expect(result.isSuccess)
        #expect(result.program.featureSets.count == 2)
    }
}
