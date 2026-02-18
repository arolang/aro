// ============================================================
// ImportTests.swift
// ARO Parser - ARO-0007 Import Tests
// ============================================================

import Testing
@testable import AROParser

// MARK: - Import Parsing Tests

@Suite("Import Parsing Tests")
struct ImportParsingTests {

    @Test("Parses single import statement")
    func testParseSingleImport() throws {
        let source = """
        import ../user-service

        (Test: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.count == 1)
        #expect(program.imports[0].path == "../user-service")
        #expect(program.featureSets.count == 1)
    }

    @Test("Parses multiple import statements")
    func testParseMultipleImports() throws {
        let source = """
        import ../auth
        import ../users
        import ../orders

        (Test: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.count == 3)
        #expect(program.imports[0].path == "../auth")
        #expect(program.imports[1].path == "../users")
        #expect(program.imports[2].path == "../orders")
    }

    @Test("Parses import with nested path")
    func testParseImportWithNestedPath() throws {
        let source = """
        import ../../shared/common
        import ./utilities

        (Test: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.count == 2)
        #expect(program.imports[0].path == "../../shared/common")
        #expect(program.imports[1].path == "./utilities")
    }

    @Test("Parses import with hyphenated name")
    func testParseImportWithHyphenatedName() throws {
        let source = """
        import ../payment-gateway
        import ../user-auth-service

        (Test: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.count == 2)
        #expect(program.imports[0].path == "../payment-gateway")
        #expect(program.imports[1].path == "../user-auth-service")
    }

    @Test("Program without imports has empty imports array")
    func testProgramWithoutImports() throws {
        let source = """
        (Test: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.isEmpty)
        #expect(program.featureSets.count == 1)
    }

    @Test("Imports must come before feature sets")
    func testImportsBeforeFeatureSets() throws {
        let source = """
        import ../auth

        (First: Demo) {
            Return an <OK: status> for the <test>.
        }

        (Second: Demo) {
            Return an <OK: status> for the <test>.
        }
        """

        let lexer = Lexer(source: source)
        let tokens = try lexer.tokenize()
        let parser = Parser(tokens: tokens)
        let program = try parser.parse()

        #expect(program.imports.count == 1)
        #expect(program.featureSets.count == 2)
    }
}

// MARK: - Import Token Tests

@Suite("Import Token Tests")
struct ImportTokenTests {

    @Test("Lexer recognizes import keyword")
    func testLexerRecognizesImport() throws {
        let tokens = try Lexer.tokenize("import")

        #expect(tokens.count == 2) // import + EOF
        #expect(tokens[0].kind == .import)
    }

    @Test("Import keyword description is correct")
    func testImportKeywordDescription() {
        #expect(TokenKind.import.description == "import")
    }
}

// MARK: - Import AST Tests

@Suite("Import AST Tests")
struct ImportASTTests {

    @Test("ImportDeclaration has correct description")
    func testImportDeclarationDescription() {
        let span = SourceSpan(start: SourceLocation(line: 1, column: 1, offset: 0),
                              end: SourceLocation(line: 1, column: 20, offset: 19))
        let importDecl = ImportDeclaration(path: "../user-service", span: span)

        #expect(importDecl.description == "import ../user-service")
    }

    @Test("Program description includes imports count")
    func testProgramDescriptionWithImports() {
        let span = SourceSpan.unknown
        let importDecl = ImportDeclaration(path: "../auth", span: span)
        let program = Program(imports: [importDecl], featureSets: [], span: span)

        #expect(program.description.contains("1 imports"))
    }
}
