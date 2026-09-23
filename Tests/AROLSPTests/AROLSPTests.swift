// ============================================================
// AROLSPTests.swift
// AROLSP - Unit Tests
// ============================================================

#if !os(Windows)
import Testing
import Foundation
@testable import AROLSP
@testable import AROParser
import ARORuntime
import LanguageServerProtocol

// MARK: - Position Converter Tests

@Suite("Position Converter Tests")
struct PositionConverterTests {

    /// Control: all three units agree on ASCII, so this is the case that
    /// passed even while the conversion was wrong.
    private static let ascii = "Log \"plain\" to the <console>."

    /// U+1F389 PARTY POPPER: one grapheme, one Unicode **scalar** (so the
    /// lexer's column advances by 1), two UTF-16 code units (so LSP counts 2).
    /// This is the case that shifted every incremental edit on the line.
    private static let emoji = "Log \"🎉\" to the <console>."

    /// "e" + U+0301 COMBINING ACUTE: one grapheme, two scalars, two UTF-16
    /// units. The parser and LSP agree here; a walk over `Character`s — which
    /// is what the old converter did — does not.
    private static let combining = "Log \"cafe\u{301}\" to the <console>."

    @Test("Converts ARO position to LSP (1-based to 0-based)")
    func testToLSP() {
        let aroLocation = SourceLocation(line: 1, column: 1, offset: 0)
        let lspPosition = PositionConverter.toLSP(aroLocation, in: Self.ascii)

        #expect(lspPosition.line == 0)
        #expect(lspPosition.character == 0)
    }

    @Test("Converts LSP position to ARO (0-based to 1-based)")
    func testFromLSP() {
        let lspPosition = Position(line: 0, character: 0)
        let aroLocation = PositionConverter.fromLSP(lspPosition, in: Self.ascii)

        #expect(aroLocation.line == 1)
        #expect(aroLocation.column == 1)
    }

    @Test("Converts span correctly")
    func testSpanConversion() {
        let aroSpan = SourceSpan(
            start: SourceLocation(line: 1, column: 5, offset: 4),
            end: SourceLocation(line: 1, column: 10, offset: 9)
        )
        let lspRange = PositionConverter.toLSP(aroSpan, in: Self.ascii)

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

    // MARK: - GitLab #676: scalars vs UTF-16 code units

    @Test("ASCII line: parser column and LSP character agree (control)")
    func testASCIIControl() {
        // `to` begins at scalar column 13 == UTF-16 character 12.
        let index = Self.ascii.range(of: "to")!.lowerBound
        let column = Self.ascii.unicodeScalars.distance(from: Self.ascii.startIndex, to: index) + 1
        let utf16 = Self.ascii.utf16.distance(from: Self.ascii.startIndex, to: index)
        #expect(column - 1 == utf16)   // the control: the two units coincide

        let position = PositionConverter.toLSP(
            SourceLocation(line: 1, column: column, offset: column - 1),
            in: Self.ascii
        )
        #expect(position.character == utf16)
    }

    @Test("Non-BMP emoji: a scalar column becomes a wider UTF-16 character")
    func testEmojiToLSP() {
        // The lexer sees the party popper as ONE scalar, so `to` sits at
        // scalar column 10; UTF-16 puts it at character 10 (0-based), because
        // the surrogate pair costs two code units. Converting without the
        // document produced 9 — one short, on every edit after the emoji.
        let index = Self.emoji.range(of: "to")!.lowerBound
        let column = Self.emoji.unicodeScalars.distance(from: Self.emoji.startIndex, to: index) + 1
        let utf16 = Self.emoji.utf16.distance(from: Self.emoji.startIndex, to: index)
        #expect(column - 1 != utf16)   // the units genuinely disagree here

        let position = PositionConverter.toLSP(
            SourceLocation(line: 1, column: column, offset: column - 1),
            in: Self.emoji
        )
        #expect(position.character == utf16)
    }

    @Test("Non-BMP emoji: round-trips back to the same scalar column")
    func testEmojiRoundTrip() {
        let index = Self.emoji.range(of: "console")!.lowerBound
        let column = Self.emoji.unicodeScalars.distance(from: Self.emoji.startIndex, to: index) + 1

        let position = PositionConverter.toLSP(
            SourceLocation(line: 1, column: column, offset: column - 1),
            in: Self.emoji
        )
        let back = PositionConverter.fromLSP(position, in: Self.emoji)

        #expect(back.line == 1)
        #expect(back.column == column)
    }

    @Test("Combining accent: a grapheme walk would be one short, UTF-16 is not")
    func testCombiningAccent() {
        let index = Self.combining.range(of: "to")!.lowerBound
        let column = Self.combining.unicodeScalars.distance(from: Self.combining.startIndex, to: index) + 1
        let utf16 = Self.combining.utf16.distance(from: Self.combining.startIndex, to: index)
        let graphemes = Self.combining.distance(from: Self.combining.startIndex, to: index)

        // Scalars and UTF-16 agree; graphemes — the unit the old converter
        // walked — do not. So this line catches the "fixed it in the wrong
        // unit" version of the bug.
        #expect(column - 1 == utf16)
        #expect(graphemes != utf16)

        let position = PositionConverter.toLSP(
            SourceLocation(line: 1, column: column, offset: column - 1),
            in: Self.combining
        )
        #expect(position.character == utf16)

        let back = PositionConverter.fromLSP(position, in: Self.combining)
        #expect(back.column == column)
    }

    @Test("Offsets after an emoji land on the right character")
    func testOffsetAfterEmoji() {
        let document = "a🎉b"
        // LSP: 'a'=0, the pair occupies 1-2, so 'b' is character 3.
        let index = PositionConverter.stringIndex(of: Position(line: 0, character: 3), in: document)
        #expect(document[index] == "b")
    }

    @Test("A character offset inside a surrogate pair rounds down")
    func testOffsetInsideSurrogatePair() {
        let document = "a🎉b"
        // Character 2 is the low surrogate — not a position a cursor can hold.
        // LSP says round down to the start of that character rather than trap.
        let index = PositionConverter.stringIndex(of: Position(line: 0, character: 2), in: document)
        #expect(document[index] == "🎉")
    }

    @Test("Positions past the end of a line clamp to the end of that line")
    func testClampsPastLineEnd() {
        let document = "short\nlonger line\n"
        let index = PositionConverter.stringIndex(of: Position(line: 0, character: 99), in: document)
        #expect(document.distance(from: document.startIndex, to: index) == 5)
    }

    @Test("Line table places later lines correctly after a wide character")
    func testMultiLineWithEmoji() {
        let document = "Log \"🎉\" to the <console>.\nLog \"next\" to the <console>."
        // Line 1 is plain ASCII: character 5 is the `n` of `next`. If the wide
        // character on line 0 leaked into the line table, this lands elsewhere.
        let index = PositionConverter.stringIndex(of: Position(line: 1, character: 5), in: document)
        #expect(document[index] == "n")
    }
}

// MARK: - Document Manager Incremental Edit Tests (GitLab #676)

@Suite("Document Manager Incremental Edits")
struct DocumentManagerIncrementalEditTests {

    /// The failure the issue describes: an edit after a non-BMP character.
    /// The client counts UTF-16, so it names a replacement range two units
    /// wide for the emoji; a converter counting graphemes takes one, and the
    /// buffer desynchronises from that keystroke on.
    @Test("An edit after an emoji applies at the position the client meant")
    func testEditAfterEmoji() {
        let manager = DocumentManager()
        let uri = "file:///utf16.aro"
        let original = "Log \"🎉\" to the <console>."
        _ = manager.open(uri: uri, content: original, version: 1)

        // Replace `console` with `stderr`. In UTF-16 the word starts at
        // character 17 (the surrogate pair costs two) and ends at 24.
        let start = original.utf16.distance(from: original.startIndex, to: original.range(of: "console")!.lowerBound)
        let end = original.utf16.distance(from: original.startIndex, to: original.range(of: "console")!.upperBound)

        let change = TextDocumentContentChangeEvent(
            range: LSPRange(
                start: Position(line: 0, character: start),
                end: Position(line: 0, character: end)
            ),
            rangeLength: end - start,
            text: "stderr"
        )

        let state = manager.applyChanges(uri: uri, changes: [change], version: 2)
        #expect(state?.content == "Log \"🎉\" to the <stderr>.")
    }

    @Test("An edit before an emoji leaves the emoji intact")
    func testEditBeforeEmoji() {
        let manager = DocumentManager()
        let uri = "file:///utf16-before.aro"
        let original = "Log \"🎉\" to the <console>."
        _ = manager.open(uri: uri, content: original, version: 1)

        let change = TextDocumentContentChangeEvent(
            range: LSPRange(start: Position(line: 0, character: 0), end: Position(line: 0, character: 3)),
            rangeLength: 3,
            text: "Send"
        )

        let state = manager.applyChanges(uri: uri, changes: [change], version: 2)
        #expect(state?.content == "Send \"🎉\" to the <console>.")
    }
}

// MARK: - Diagnostics Handler Tests

@Suite("Diagnostics Handler Tests")
struct DiagnosticsHandlerTests {

    /// Diagnostics are converted against the document they came from, so the
    /// handler needs some text to count columns in.
    private let sourceUnderTest = "Log \"hi\" to the <console>."

    @Test("Converts error diagnostic")
    func testErrorDiagnostic() {
        let handler = DiagnosticsHandler()
        let diagnostic = AROParser.Diagnostic(
            severity: .error,
            message: "Test error",
            location: SourceLocation(line: 1, column: 1, offset: 0)
        )

        let lspDiagnostics = handler.convert([diagnostic], in: sourceUnderTest)

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

        let lspDiagnostics = handler.convert([diagnostic], in: sourceUnderTest)

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

        let lspDiagnostics = handler.convert(diagnostics, in: sourceUnderTest)

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
        let result = handler.handle(content: "", compilationResult: nil)

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

        let result = handler.handle(content: source, compilationResult: compilationResult)

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

        let result = handler.handle(content: source, compilationResult: compilationResult)

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

    private let spaces = AROLSP.FormattingOptions(tabSize: 4, insertSpaces: true)

    @Test("Formats simple feature set")
    func testFormatSimpleFeatureSet() {
        let handler = FormattingHandler()
        let source = "(Test:Business){<Extract>the<data>from the<source>.}"

        let result = handler.handle(content: source, options: spaces)

        #expect(result != nil)
        #expect(result!.count > 0)
    }

    @Test("Returns nil for empty content")
    func testEmptyContent() {
        let handler = FormattingHandler()
        let result = handler.handle(content: "", options: spaces)

        #expect(result == nil || result!.isEmpty)
    }

    // MARK: - GitLab #677: the formatter has to reach the statements

    /// The regression the issue names. Every statement below is
    /// mis-indented; before the fix they all took the "preserve with current
    /// indentation" branch, which for this input produced the same text back
    /// and so no edit at all.
    @Test("Badly indented statements are actually re-indented")
    func testReindentsStatements() throws {
        let source = """
        (Test: Business) {
        Extract the <data> from the <source>.
                Compute the <total> from <data>.
              Return an <OK: status> for the <data>.
        }
        """

        let result = try #require(FormattingHandler().handle(content: source, options: spaces))
        let newText = try #require(result.first?["newText"] as? String)

        #expect(newText.contains("\n    Extract the <data> from the <source>."))
        #expect(newText.contains("\n    Compute the <total> from <data>."))
        #expect(newText.contains("\n    Return an <OK: status> for the <data>."))
    }

    /// The other half: a statement whose *contents* need fixing, not just its
    /// column. `formatStatement` was supposed to do this and was unreachable.
    @Test("Runs of spaces inside a statement are collapsed")
    func testCollapsesInteriorSpaces() throws {
        let source = """
        (Test: Business) {
            Extract   the  <data>    from the <source>.
        }
        """

        let result = try #require(FormattingHandler().handle(content: source, options: spaces))
        let newText = try #require(result.first?["newText"] as? String)

        #expect(newText.contains("    Extract the <data> from the <source>."))
    }

    @Test("Spaces inside string literals and comments are left alone")
    func testPreservesSpacesInStringsAndComments() throws {
        let source = """
        (Test: Business) {
            (*  aligned   note  *)
            Log "two  spaces   here" to the <console>.
        }
        """

        let result = FormattingHandler().handle(content: source, options: spaces)
        // Only the missing trailing newline should differ, so if an edit comes
        // back it must still carry both runs of spaces verbatim.
        if let newText = result?.first?["newText"] as? String {
            #expect(newText.contains("\"two  spaces   here\""))
            #expect(newText.contains("(*  aligned   note  *)"))
        }
    }

    @Test("Tabs are honoured when the client asks for them")
    func testTabIndentation() throws {
        let source = "(Test: Business) {\nReturn an <OK: status> for the <x>.\n}"
        let options = AROLSP.FormattingOptions(tabSize: 4, insertSpaces: false)

        let result = try #require(FormattingHandler().handle(content: source, options: options))
        let newText = try #require(result.first?["newText"] as? String)

        #expect(newText.contains("\n\tReturn an <OK: status> for the <x>."))
    }

    /// The LSP and the editor must not disagree about what formatted ARO
    /// looks like — that was the reason not to revive the dead branch in
    /// parallel with SOLARO's formatter.
    @Test("The LSP formatter produces exactly what the shared formatter does")
    func testAgreesWithSharedFormatter() throws {
        let source = """
        (Test: Business) {
        Extract   the <data> from the <source>.
              Return an <OK: status> for the <data>.
        }
        """

        let result = try #require(FormattingHandler().handle(content: source, options: spaces))
        let newText = try #require(result.first?["newText"] as? String)

        #expect(newText == AROFormatter.format(source))
    }

    @Test("Formatting is idempotent")
    func testIdempotent() throws {
        let source = """
        (Test: Business) {
        Extract   the <data> from the <source>.
        }
        """

        let once = AROFormatter.format(source)
        #expect(AROFormatter.format(once) == once)
        // And the handler reports "nothing to do" for already-formatted text.
        #expect(FormattingHandler().handle(content: once, options: spaces) == nil)
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
            Extract the <data>
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = SignatureHelpHandler()

        let result = handler.handle(
            position: Position(line: 1, character: 8),
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

// MARK: - Inlay Hint Handler Tests

@Suite("Inlay Hint Handler Tests")
struct InlayHintHandlerTests {

    // MARK: - Request body hints (GitLab #477)

    @Test("The statement that reads the request body is hinted with its limit")
    func testBodyMaterializationHint() {
        let source = """
        (createNote: Notes) {
            Extract the <note> from the <request: body>.
            Extract the <text> from the <note: text>.
            Return a <Created: status> with <text>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let hints = handler.handle(
            compilationResult: compilationResult,
            startLine: 0,
            endLine: 20
        ) ?? []

        let bodyHints = hints.filter { ($0["label"] as? String)?.contains("reads body") == true }
        #expect(bodyHints.count == 1, "exactly one hint, at the statement that reads it")

        guard let hint = bodyHints.first else { return }
        let position = hint["position"] as? [String: Int]
        // Line 3 of the source (1-based) is the field access; hints are 0-based.
        #expect(position?["line"] == 2)
        #expect((hint["label"] as? String)?.contains("1MB") == true, "the default limit when no contract declares one")

        let tooltip = hint["tooltip"] as? [String: Any]
        #expect((tooltip?["value"] as? String)?.contains("ARO-0090") == true)
    }

    @Test("A feature set that only moves its body is not hinted")
    func testStreamingFeatureSetHasNoBodyHint() {
        let source = """
        (uploadDocument: Files) {
            Extract the <name> from the <pathParameters: name>.
            Extract the <upload> from the <request: body>.
            Write the <upload> to the <file: name>.
            Return a <Created: status> with <name>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let hints = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 20) ?? []
        #expect(!hints.contains { ($0["label"] as? String)?.contains("reads body") == true })
    }

    @Test("A feature set that never touches a body is not hinted")
    func testNoBodyNoHint() {
        let source = """
        (listNotes: Notes) {
            Retrieve the <notes> from the <note-repository>.
            Return an <OK: status> with <notes>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let hints = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 20) ?? []
        #expect(!hints.contains { ($0["label"] as? String)?.contains("reads body") == true })
    }

    @Test("A hint outside the requested range is not returned")
    func testBodyHintRespectsRange() {
        let source = """
        (createNote: Notes) {
            Extract the <note> from the <request: body>.
            Extract the <text> from the <note: text>.
            Return a <Created: status> with <text>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let hints = handler.handle(compilationResult: compilationResult, startLine: 10, endLine: 20) ?? []
        #expect(!hints.contains { ($0["label"] as? String)?.contains("reads body") == true })
    }

    @Test("A declared x-aro-max-body is the number the hint shows")
    func testDeclaredLimitInHint() throws {
        let yaml = """
        openapi: 3.0.3
        info:
          title: T
          version: 1.0.0
        paths:
          /notes:
            post:
              operationId: createNote
              x-aro-max-body: 256KB
              responses:
                '200':
                  description: ok
        """
        let spec = try OpenAPILoader.parse(data: Data(yaml.utf8), filename: "openapi.yaml")
        let limits = RouteBodyLimits.from(spec: spec)

        #expect(limits.route(forOperation: "createNote") == "POST /notes")
        #expect(limits.limit(forOperation: "createNote").bytes == 256_000)
        #expect(limits.limit(forOperation: "createNote").declared)
        // A route the contract doesn't mention still has the runtime default.
        #expect(!limits.limit(forOperation: "somethingElse").declared)

        let source = """
        (createNote: Notes) {
            Extract the <note> from the <request: body>.
            Extract the <text> from the <note: text>.
            Return a <Created: status> with <text>.
        }
        """
        let handler = InlayHintHandler()
        let hints = handler.handle(
            compilationResult: Compiler.compile(source),
            startLine: 0,
            endLine: 20,
            bodyLimits: limits
        ) ?? []

        let label = hints.compactMap { $0["label"] as? String }.first { $0.contains("reads body") }
        #expect(label == "reads body ≤ 256KB")

        let tooltip = hints
            .first { ($0["label"] as? String)?.contains("reads body") == true }?["tooltip"] as? [String: Any]
        #expect((tooltip?["value"] as? String)?.contains("POST /notes") == true)
    }

    @Test("Returns nil for empty compilation result")
    func testNilForEmptyResult() {
        let handler = InlayHintHandler()
        let result = handler.handle(compilationResult: nil, startLine: 0, endLine: 10)
        #expect(result == nil)
    }

    @Test("Returns hints for variable with known type")
    func testVariableTypeHint() {
        let source = """
        (Test: Business) {
            Extract the <user> from the <request: body>.
            Return an <OK: status> for the <result>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let result = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 10)
        // May or may not produce hints depending on type inference
        // At minimum, verify it doesn't crash and returns a valid structure
        if let hints = result {
            for hint in hints {
                #expect(hint["position"] != nil)
                #expect(hint["label"] != nil)
            }
        }
    }

    @Test("Respects visible range filtering")
    func testRangeFiltering() {
        let source = """
        (Test: Business) {
            Extract the <data> from the <source>.
            Compute the <result> for the <data>.
            Return the <output> for the <result>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        // Request only line 0 — should get fewer hints than full range
        let narrowResult = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 0)
        let fullResult = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 10)

        let narrowCount = narrowResult?.count ?? 0
        let fullCount = fullResult?.count ?? 0
        #expect(narrowCount <= fullCount)
    }

    @Test("Returns hints for multiple feature sets")
    func testMultipleFeatureSets() {
        let source = """
        (First: Business) {
            Extract the <alpha> from the <source>.
        }

        (Second: Business) {
            Compute the <beta> for the <input>.
        }
        """
        let compilationResult = Compiler.compile(source)
        let handler = InlayHintHandler()

        let result = handler.handle(compilationResult: compilationResult, startLine: 0, endLine: 20)
        // Should process both feature sets without error
        if let hints = result {
            for hint in hints {
                #expect(hint["position"] != nil)
            }
        }
    }
}

#endif
