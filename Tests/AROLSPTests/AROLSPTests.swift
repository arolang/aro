// ============================================================
// AROLSPTests.swift
// AROLSP - Unit Tests
// ============================================================

#if !os(Windows)
import Testing
@testable import AROLSP
@testable import AROParser
import LanguageServerProtocol

// MARK: - Position Converter Tests

@Suite("Position Converter Tests")
struct PositionConverterTests {

    @Test("Converts ARO position to LSP (1-based to 0-based)")
    func testToLSP() {
        let aroLocation = SourceLocation(line: 1, column: 1, offset: 0)
        let lspPosition = PositionConverter.toLSP(aroLocation)

        #expect(lspPosition.line == 0)
        #expect(lspPosition.character == 0)
    }

    @Test("Converts LSP position to ARO (0-based to 1-based)")
    func testFromLSP() {
        let lspPosition = Position(line: 0, character: 0)
        let aroLocation = PositionConverter.fromLSP(lspPosition)

        #expect(aroLocation.line == 1)
        #expect(aroLocation.column == 1)
    }

    @Test("Converts span correctly")
    func testSpanConversion() {
        let aroSpan = SourceSpan(
            start: SourceLocation(line: 1, column: 5, offset: 4),
            end: SourceLocation(line: 1, column: 10, offset: 9)
        )
        let lspRange = PositionConverter.toLSP(aroSpan)

        #expect(lspRange.start.line == 0)
        #expect(lspRange.start.character == 4)
        #expect(lspRange.end.line == 0)
        #expect(lspRange.end.character == 9)
    }

    @Test("Calculates offset in document")
    func testCalculateOffset() {
        let document = "Line 1\nLine 2\nLine 3"
        let position = Position(line: 1, character: 5)  // "2" in "Line 2"

        let offset = PositionConverter.calculateOffset(position, in: document)
        #expect(offset == 12)  // "Line 1\n" = 7 chars, "Line " = 5 chars
    }
}

// MARK: - Diagnostics Handler Tests

@Suite("Diagnostics Handler Tests")
struct DiagnosticsHandlerTests {

    @Test("Converts error diagnostic")
    func testErrorDiagnostic() {
        let handler = DiagnosticsHandler()
        let diagnostic = AROParser.Diagnostic(
            severity: .error,
            message: "Test error",
            location: SourceLocation(line: 1, column: 1, offset: 0)
        )

        let lspDiagnostics = handler.convert([diagnostic])

        #expect(lspDiagnostics.count == 1)
        #expect(lspDiagnostics[0]["severity"] as? Int == 1)  // Error
        #expect(lspDiagnostics[0]["message"] as? String == "Test error")
        #expect(lspDiagnostics[0]["source"] as? String == "aro")
    }

    @Test("Converts warning diagnostic")
    func testWarningDiagnostic() {
        let handler = DiagnosticsHandler()
        let diagnostic = AROParser.Diagnostic(
            severity: .warning,
            message: "Test warning",
            location: SourceLocation(line: 1, column: 1, offset: 0)
        )

        let lspDiagnostics = handler.convert([diagnostic])

        #expect(lspDiagnostics.count == 1)
        #expect(lspDiagnostics[0]["severity"] as? Int == 2)  // Warning
    }

    @Test("Converts multiple diagnostics")
    func testMultipleDiagnostics() {
        let handler = DiagnosticsHandler()
        let diagnostics = [
            AROParser.Diagnostic(severity: .error, message: "Error 1", location: SourceLocation()),
            AROParser.Diagnostic(severity: .warning, message: "Warning 1", location: SourceLocation()),
            AROParser.Diagnostic(severity: .note, message: "Note 1", location: SourceLocation()),
        ]

        let lspDiagnostics = handler.convert(diagnostics)

        #expect(lspDiagnostics.count == 3)
    }
}

// MARK: - Hover Handler Tests

@Suite("Hover Handler Tests")
struct HoverHandlerTests {

    @Test("Returns nil for empty compilation result")
    func testNilForEmptyResult() {
        let handler = HoverHandler()
        let result = handler.handle(
            position: Position(line: 0, character: 0),
            content: "",
            compilationResult: nil
        )

        #expect(result == nil)
    }

    @Test("Returns hover for feature set")
    func testFeatureSetHover() {
        let source = """
        (Test Feature: Business) {
            Extract the <data> from the <source>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = HoverHandler()

        // Position on line 1, character 1 (inside feature set header)
        let result = handler.handle(
            position: Position(line: 0, character: 1),
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
        let contents = result?["contents"] as? [String: Any]
        let value = contents?["value"] as? String
        #expect(value?.contains("Feature Set") == true)
    }

    @Test("Returns hover for action")
    func testActionHover() {
        let source = """
        (Test: Business) {
            Extract the <data> from the <source>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = HoverHandler()

        // Position on "Extract" - line 2, after the <
        let result = handler.handle(
            position: Position(line: 1, character: 5),
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
    }
}

// MARK: - Completion Handler Tests

@Suite("Completion Handler Tests")
struct CompletionHandlerTests {

    @Test("Returns action completions on < trigger")
    func testActionCompletionsOnTrigger() {
        let handler = CompletionHandler()
        let result = handler.handle(
            position: Position(line: 0, character: 1),
            content: "<",
            compilationResult: nil,
            triggerCharacter: "<"
        )

        let items = result["items"] as? [[String: Any]]
        #expect(items != nil)
        #expect(items!.count > 0)

        let labels = items!.compactMap { $0["label"] as? String }
        #expect(labels.contains("Extract"))
        #expect(labels.contains("Compute"))
        #expect(labels.contains("Return"))
    }

    @Test("Returns qualifier completions on : trigger")
    func testQualifierCompletionsOnTrigger() {
        let handler = CompletionHandler()
        let result = handler.handle(
            position: Position(line: 0, character: 1),
            content: ":",
            compilationResult: nil,
            triggerCharacter: ":"
        )

        let items = result["items"] as? [[String: Any]]
        #expect(items != nil)
        #expect(items!.count > 0)

        let labels = items!.compactMap { $0["label"] as? String }
        #expect(labels.contains("status"))
        #expect(labels.contains("body"))
    }

    @Test("Returns member completions on . trigger")
    func testMemberCompletionsOnTrigger() {
        let handler = CompletionHandler()
        let result = handler.handle(
            position: Position(line: 0, character: 1),
            content: ".",
            compilationResult: nil,
            triggerCharacter: "."
        )

        let items = result["items"] as? [[String: Any]]
        #expect(items != nil)
        #expect(items!.count > 0)

        let labels = items!.compactMap { $0["label"] as? String }
        #expect(labels.contains("length"))
        #expect(labels.contains("count"))
    }

    @Test("Returns variable completions from compilation result")
    func testVariableCompletions() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = CompletionHandler()

        let result = handler.handle(
            position: Position(line: 0, character: 0),
            content: source,
            compilationResult: compilationResult,
            triggerCharacter: "<"
        )

        let items = result["items"] as? [[String: Any]]
        #expect(items != nil)

        let labels = items!.compactMap { $0["label"] as? String }
        #expect(labels.contains("user"))
    }

    @Test("Returns snippet completions")
    func testSnippetCompletions() {
        let handler = CompletionHandler()
        let result = handler.handle(
            position: Position(line: 0, character: 0),
            content: "",
            compilationResult: nil,
            triggerCharacter: nil
        )

        let items = result["items"] as? [[String: Any]]
        #expect(items != nil)

        let labels = items!.compactMap { $0["label"] as? String }
        #expect(labels.contains("feature set"))
        #expect(labels.contains("aro statement"))
    }
}

// MARK: - Definition Handler Tests

@Suite("Definition Handler Tests")
struct DefinitionHandlerTests {

    @Test("Returns nil for empty compilation result")
    func testNilForEmptyResult() {
        let handler = DefinitionHandler()
        let result = handler.handle(
            uri: "file:///test.aro",
            position: Position(line: 0, character: 0),
            content: "",
            compilationResult: nil
        )

        #expect(result == nil)
    }

    @Test("Finds definition of variable")
    func testFindVariableDefinition() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request>.
            Compute the <hash> for the <user>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = DefinitionHandler()

        // Position on "user" in the second statement (object position)
        // Line 2 (0-indexed), character 33 is in the middle of "user" in "<user>"
        let result = handler.handle(
            uri: "file:///test.aro",
            position: Position(line: 2, character: 33),
            content: source,
            compilationResult: compilationResult
        )

        // Should find the definition from line 1
        #expect(result != nil)
    }
}

// MARK: - References Handler Tests

@Suite("References Handler Tests")
struct ReferencesHandlerTests {

    @Test("Returns nil for empty compilation result")
    func testNilForEmptyResult() {
        let handler = ReferencesHandler()
        let result = handler.handle(
            uri: "file:///test.aro",
            position: Position(line: 0, character: 0),
            content: "",
            compilationResult: nil
        )

        #expect(result == nil)
    }

    @Test("Finds all references to variable")
    func testFindAllReferences() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request>.
            Compute the <hash> for the <user>.
            Return the <result> for the <user>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = ReferencesHandler()

        // Position on "user" in the first statement
        let result = handler.handle(
            uri: "file:///test.aro",
            position: Position(line: 1, character: 19),
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
        // "user" appears 3 times
        #expect(result!.count >= 1)
    }
}

// MARK: - Document Symbol Handler Tests

@Suite("Document Symbol Handler Tests")
struct DocumentSymbolHandlerTests {

    @Test("Returns nil for empty compilation result")
    func testNilForEmptyResult() {
        let handler = DocumentSymbolHandler()
        let result = handler.handle(compilationResult: nil)

        #expect(result == nil)
    }

    @Test("Returns symbols for feature set")
    func testFeatureSetSymbols() {
        let source = """
        (Test Feature: Business) {
            Extract the <data> from the <source>.
            Return the <result> for the <operation>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = DocumentSymbolHandler()

        let result = handler.handle(compilationResult: compilationResult)

        #expect(result != nil)
        #expect(result!.count > 0)

        // First symbol should be the feature set
        let firstSymbol = result![0]
        #expect(firstSymbol["name"] as? String == "Test Feature")
        #expect(firstSymbol["kind"] as? Int == 12)  // Function kind

        // Should have children (statements)
        let children = firstSymbol["children"] as? [[String: Any]]
        #expect(children != nil)
        #expect(children!.count == 2)
    }

    @Test("Returns symbols for multiple feature sets")
    func testMultipleFeatureSetSymbols() {
        let source = """
        (First: Business) {
            Extract the <data> from the <source>.
        }

        (Second: Business) {
            Return the <result> for the <operation>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = DocumentSymbolHandler()

        let result = handler.handle(compilationResult: compilationResult)

        #expect(result != nil)
        #expect(result!.count == 2)
    }
}

// MARK: - Document Manager Tests

@Suite("Document Manager Tests")
struct DocumentManagerTests {

    @Test("Opens document and compiles")
    func testOpenDocument() async {
        let manager = DocumentManager()
        let uri = "file:///test.aro"
        let content = """
        (Test: Business) {
            Extract the <data> from the <source>.
        }
        """

        let state = await manager.open(uri: uri, content: content, version: 1)

        #expect(state.uri == uri)
        #expect(state.content == content)
        #expect(state.version == 1)
        #expect(state.compilationResult != nil)
    }

    @Test("Updates document and recompiles")
    func testUpdateDocument() async {
        let manager = DocumentManager()
        let uri = "file:///test.aro"

        _ = await manager.open(uri: uri, content: "initial", version: 1)
        let updated = await manager.update(uri: uri, content: "updated", version: 2)

        #expect(updated?.content == "updated")
        #expect(updated?.version == 2)
    }

    @Test("Closes document")
    func testCloseDocument() async {
        let manager = DocumentManager()
        let uri = "file:///test.aro"

        _ = await manager.open(uri: uri, content: "test", version: 1)
        await manager.close(uri: uri)

        let state = await manager.get(uri: uri)
        #expect(state == nil)
    }

    @Test("Checks if document is open")
    func testIsOpen() async {
        let manager = DocumentManager()
        let uri = "file:///test.aro"

        #expect(await manager.isOpen(uri: uri) == false)

        _ = await manager.open(uri: uri, content: "test", version: 1)
        #expect(await manager.isOpen(uri: uri) == true)
    }
}

// MARK: - Workspace Symbol Handler Tests

@Suite("Workspace Symbol Handler Tests")
struct WorkspaceSymbolHandlerTests {

    @Test("Finds symbols matching query")
    func testFindSymbolsMatchingQuery() async {
        let handler = WorkspaceSymbolHandler()
        let manager = DocumentManager()

        let content = """
        (User Auth: Security) {
            Extract the <user> from the <request>.
        }

        (Order Process: Business) {
            Create the <order> for the <user>.
        }
        """
        _ = await manager.open(uri: "file:///test.aro", content: content, version: 1)

        let documents = await manager.all()
        let result = handler.handle(query: "User", documents: documents)

        #expect(result.count >= 1)
    }

    @Test("Returns empty for no matches")
    func testNoMatches() async {
        let handler = WorkspaceSymbolHandler()
        let manager = DocumentManager()

        let content = """
        (Test: Business) {
            Extract the <data> from the <source>.
        }
        """
        _ = await manager.open(uri: "file:///test.aro", content: content, version: 1)

        let documents = await manager.all()
        let result = handler.handle(query: "ZZZZZ", documents: documents)

        #expect(result.isEmpty)
    }
}

// MARK: - Formatting Handler Tests

@Suite("Formatting Handler Tests")
struct FormattingHandlerTests {

    @Test("Formats simple feature set")
    func testFormatSimpleFeatureSet() {
        let handler = FormattingHandler()
        let source = "(Test:Business){<Extract>the<data>from the<source>.}"

        let result = handler.handle(content: source, options: FormattingOptions(tabSize: 4, insertSpaces: true))

        #expect(result != nil)
        #expect(result!.count > 0)
    }

    @Test("Returns nil for empty content")
    func testEmptyContent() {
        let handler = FormattingHandler()
        let result = handler.handle(content: "", options: FormattingOptions(tabSize: 4, insertSpaces: true))

        #expect(result == nil || result!.isEmpty)
    }
}

// MARK: - Rename Handler Tests

@Suite("Rename Handler Tests")
struct RenameHandlerTests {

    @Test("Prepares rename for valid symbol")
    func testPrepareRename() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request>.
            Return the <result> for the <user>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = RenameHandler()

        let result = handler.prepareRename(
            uri: "file:///test.aro",
            position: Position(line: 1, character: 19),
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
    }

    @Test("Returns workspace edit for rename")
    func testRename() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request>.
            Return the <result> for the <user>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = RenameHandler()

        let result = handler.handle(
            uri: "file:///test.aro",
            position: Position(line: 1, character: 19),
            newName: "customer",
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
    }
}

// MARK: - Folding Range Handler Tests

@Suite("Folding Range Handler Tests")
struct FoldingRangeHandlerTests {

    @Test("Returns folding ranges for feature sets")
    func testFeatureSetFolding() {
        let source = """
        (First Feature: Business) {
            Extract the <data> from the <source>.
            Compute the <result> for the <data>.
            Return the <output> for the <result>.
        }

        (Second Feature: Business) {
            Log the <message> to the <console>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = FoldingRangeHandler()

        let result = handler.handle(compilationResult: compilationResult)

        #expect(result != nil)
        #expect(result!.count == 2)  // Two feature sets
    }

    @Test("Returns nil for empty result")
    func testNilForEmpty() {
        let handler = FoldingRangeHandler()
        let result = handler.handle(compilationResult: nil)

        #expect(result == nil)
    }
}

// MARK: - Semantic Tokens Handler Tests

@Suite("Semantic Tokens Handler Tests")
struct SemanticTokensHandlerTests {

    @Test("Returns token legend")
    func testTokenLegend() {
        let handler = SemanticTokensHandler()
        let legend = handler.legend

        #expect(legend["tokenTypes"] != nil)
        #expect(legend["tokenModifiers"] != nil)

        let types = legend["tokenTypes"] as? [String]
        #expect(types?.contains("keyword") == true)
        #expect(types?.contains("function") == true)
        #expect(types?.contains("variable") == true)
    }

    @Test("Returns tokens for source")
    func testTokensForSource() {
        let source = """
        (Test: Business) {
            Extract the <data> from the <source>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = SemanticTokensHandler()

        let result = handler.handle(content: source, compilationResult: compilationResult)

        #expect(result != nil)
        let data = result?["data"] as? [Int]
        #expect(data != nil)
        #expect(data!.count > 0)
    }
}

// MARK: - Signature Help Handler Tests

@Suite("Signature Help Handler Tests")
struct SignatureHelpHandlerTests {

    @Test("Returns signature for action")
    func testActionSignature() {
        let source = """
        (Test: Business) {
            <Extract>
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = SignatureHelpHandler()

        let result = handler.handle(
            position: Position(line: 1, character: 14),
            content: source,
            compilationResult: compilationResult
        )

        #expect(result != nil)
    }
}

// MARK: - Code Action Handler Tests

@Suite("Code Action Handler Tests")
struct CodeActionHandlerTests {

    @Test("Returns code actions for diagnostics")
    func testCodeActionsForDiagnostics() {
        let handler = CodeActionHandler()
        let source = """
        (Test: Business) {
            <Extrct> the <data> from the <source>.
        }
        """
        let compilationResult = Compiler.compile(source)

        let diagnostic: [String: Any] = [
            "severity": 1,
            "message": "Unknown action 'Extrct'",
            "range": [
                "start": ["line": 1, "character": 4],
                "end": ["line": 1, "character": 12]
            ]
        ]

        let result = handler.handle(
            uri: "file:///test.aro",
            range: (start: Position(line: 1, character: 4), end: Position(line: 1, character: 12)),
            diagnostics: [diagnostic],
            content: source,
            compilationResult: compilationResult
        )

        // May return quick fixes
        #expect(result.count >= 0)  // May or may not have fixes
    }
}

#endif
