// ============================================================
// AROLanguageServer.swift
// AROLSP - Main Language Server Implementation
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// ARO Language Server implementing the Language Server Protocol
public final class AROLanguageServer: Sendable {

    // MARK: - Properties

    private let documentManager: DocumentManager
    private let hoverHandler: HoverHandler
    private let definitionHandler: DefinitionHandler
    private let completionHandler: CompletionHandler
    private let referencesHandler: ReferencesHandler
    private let documentSymbolHandler: DocumentSymbolHandler
    private let diagnosticsHandler: DiagnosticsHandler
    private let renameHandler: RenameHandler
    private let workspaceSymbolHandler: WorkspaceSymbolHandler
    private let formattingHandler: FormattingHandler
    private let foldingRangeHandler: FoldingRangeHandler
    private let semanticTokensHandler: SemanticTokensHandler
    private let signatureHelpHandler: SignatureHelpHandler
    private let codeActionHandler: CodeActionHandler

    private let debugMode: Bool

    // MARK: - Initialization

    public init(debug: Bool = false) {
        self.debugMode = debug
        self.documentManager = DocumentManager()
        self.hoverHandler = HoverHandler()
        self.definitionHandler = DefinitionHandler()
        self.completionHandler = CompletionHandler()
        self.referencesHandler = ReferencesHandler()
        self.documentSymbolHandler = DocumentSymbolHandler()
        self.diagnosticsHandler = DiagnosticsHandler()
        self.renameHandler = RenameHandler()
        self.workspaceSymbolHandler = WorkspaceSymbolHandler()
        self.formattingHandler = FormattingHandler()
        self.foldingRangeHandler = FoldingRangeHandler()
        self.semanticTokensHandler = SemanticTokensHandler()
        self.signatureHelpHandler = SignatureHelpHandler()
        self.codeActionHandler = CodeActionHandler()
    }

    // MARK: - Server Capabilities

    /// Server capabilities as a dictionary for the initialize response
    private var capabilitiesDict: [String: Any] {
        [
            "textDocumentSync": [
                "openClose": true,
                "change": 2,  // Incremental sync
                "save": ["includeText": true]
            ],
            "hoverProvider": true,
            "completionProvider": [
                "triggerCharacters": ["<", ":", "."],
                "resolveProvider": false
            ],
            "definitionProvider": true,
            "documentHighlightProvider": true,
            "referencesProvider": true,
            "documentSymbolProvider": true,
            "workspaceSymbolProvider": true,
            "documentFormattingProvider": true,
            "renameProvider": [
                "prepareProvider": true
            ],
            "foldingRangeProvider": true,
            // Semantic tokens disabled - they override TextMate grammar and cause
            // highlighting issues (first letter appears in different color)
            // "semanticTokensProvider": [
            //     "legend": semanticTokensHandler.legend,
            //     "full": true,
            //     "range": false
            // ],
            "signatureHelpProvider": [
                "triggerCharacters": ["<", " "],
                "retriggerCharacters": [","]
            ],
            "codeActionProvider": [
                "codeActionKinds": ["quickfix", "refactor"]
            ]
        ]
    }

    // MARK: - Debug Logging

    private func log(_ message: String) {
        if debugMode {
            FileHandle.standardError.write("[\(timestamp())] \(message)\n".data(using: .utf8)!)
        }
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Stdio Transport

    /// Run the language server using stdio transport
    public func runStdio() async throws {
        log("ARO Language Server starting...")

        // Read using FileHandle's bytes async sequence for proper async handling
        var buffer = Data()
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput

        // Set stdin to non-blocking might help with VSCode spawning
        let flags = fcntl(input.fileDescriptor, F_GETFL)
        if flags != -1 {
            _ = fcntl(input.fileDescriptor, F_SETFL, flags & ~O_NONBLOCK)
        }

        while true {
            // Read available data
            let data = input.availableData
            if data.isEmpty {
                log("EOF received, shutting down")
                break
            }
            buffer.append(data)

            // Try to parse complete messages
            while let message = try extractMessage(from: &buffer) {
                log("Received message: \(String(data: message.prefix(200), encoding: .utf8) ?? "...")")
                let response = await handleMessage(message)
                if let response = response {
                    log("Sending response: \(String(data: response.prefix(200), encoding: .utf8) ?? "...")")
                    try sendMessage(response, to: output)
                }
            }
        }
    }

    /// Run the language server synchronously (for compatibility with child process spawning)
    public func runStdioSync() {
        // Ignore signals that can crash the process when spawned by VSCode
        signal(SIGPIPE, SIG_IGN)

        log("ARO Language Server starting...")

        // Use a simple blocking read loop on the main thread
        var buffer = Data()
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput
        var readBuffer = [UInt8](repeating: 0, count: 4096)

        while true {
            // Use POSIX read which blocks properly
            let bytesRead = read(STDIN_FILENO, &readBuffer, readBuffer.count)
            if bytesRead <= 0 {
                log("EOF received, shutting down")
                break
            }
            buffer.append(contentsOf: readBuffer[0..<bytesRead])

            // Process complete messages
            while let message = try? extractMessage(from: &buffer) {
                log("Received message: \(String(data: message.prefix(200), encoding: .utf8) ?? "...")")
                if let response = handleMessageSync(message) {
                    log("Sending response: \(String(data: response.prefix(200), encoding: .utf8) ?? "...")")
                    try? sendMessage(response, to: output)
                }
            }
        }
    }

    /// Handle message synchronously without any async/await
    private func handleMessageSync(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }

        let id = json["id"]
        let params = json["params"]

        log("Handling method: \(method)")

        let result: Any?

        switch method {
        case "initialize":
            result = handleInitializeSync(params: params)

        case "initialized", "textDocument/didOpen", "textDocument/didChange",
             "textDocument/didClose", "textDocument/didSave", "$/cancelRequest":
            // Notifications - handle but don't respond
            handleNotificationSync(method: method, params: params)
            return nil

        case "shutdown":
            result = nil

        case "exit":
            exit(0)

        case "textDocument/hover":
            result = handleHoverSync(params: params)

        case "textDocument/definition":
            result = handleDefinitionSync(params: params)

        case "textDocument/documentHighlight":
            result = handleDocumentHighlightSync(params: params)

        case "textDocument/completion":
            result = handleCompletionSync(params: params)

        case "textDocument/references":
            result = handleReferencesSync(params: params)

        case "textDocument/documentSymbol":
            result = handleDocumentSymbolSync(params: params)

        case "workspace/symbol":
            result = handleWorkspaceSymbolSync(params: params)

        case "textDocument/formatting":
            result = handleFormattingSync(params: params)

        case "textDocument/prepareRename":
            result = handlePrepareRenameSync(params: params)

        case "textDocument/rename":
            result = handleRenameSync(params: params)

        case "textDocument/foldingRange":
            result = handleFoldingRangeSync(params: params)

        case "textDocument/semanticTokens/full":
            result = handleSemanticTokensSync(params: params)

        case "textDocument/signatureHelp":
            result = handleSignatureHelpSync(params: params)

        case "textDocument/codeAction":
            result = handleCodeActionSync(params: params)

        default:
            log("Unknown method: \(method)")
            if id != nil {
                return createErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
            return nil
        }

        if let id = id {
            return createSuccessResponse(id: id, result: result)
        }

        return nil
    }

    // MARK: - Synchronous Handlers

    private func handleInitializeSync(params: Any?) -> [String: Any] {
        log("Initialize request received")
        return [
            "capabilities": capabilitiesDict,
            "serverInfo": [
                "name": "aro-lsp",
                "version": "1.1.0"
            ]
        ]
    }

    private func handleNotificationSync(method: String, params: Any?) {
        switch method {
        case "textDocument/didOpen":
            guard let dict = params as? [String: Any],
                  let textDocument = dict["textDocument"] as? [String: Any],
                  let uri = textDocument["uri"] as? String,
                  let text = textDocument["text"] as? String,
                  let version = textDocument["version"] as? Int else { return }
            log("Document opened: \(uri)")
            documentManager.openSync(uri: uri, content: text, version: version)

        case "textDocument/didChange":
            guard let dict = params as? [String: Any],
                  let textDocument = dict["textDocument"] as? [String: Any],
                  let uri = textDocument["uri"] as? String,
                  let version = textDocument["version"] as? Int,
                  let contentChanges = dict["contentChanges"] as? [[String: Any]] else { return }
            log("Document changed: \(uri)")
            var changes: [TextDocumentContentChangeEvent] = []
            for change in contentChanges {
                let text = change["text"] as? String ?? ""
                if let rangeDict = change["range"] as? [String: Any],
                   let startDict = rangeDict["start"] as? [String: Any],
                   let endDict = rangeDict["end"] as? [String: Any],
                   let startLine = startDict["line"] as? Int,
                   let startChar = startDict["character"] as? Int,
                   let endLine = endDict["line"] as? Int,
                   let endChar = endDict["character"] as? Int {
                    let range = LSPRange(
                        start: Position(line: startLine, character: startChar),
                        end: Position(line: endLine, character: endChar)
                    )
                    changes.append(TextDocumentContentChangeEvent(range: range, rangeLength: nil, text: text))
                } else {
                    changes.append(TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text))
                }
            }
            documentManager.applyChangesSync(uri: uri, changes: changes, version: version)

        case "textDocument/didClose":
            guard let dict = params as? [String: Any],
                  let textDocument = dict["textDocument"] as? [String: Any],
                  let uri = textDocument["uri"] as? String else { return }
            log("Document closed: \(uri)")
            documentManager.closeSync(uri: uri)

        default:
            break
        }
    }

    private func handleHoverSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return hoverHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDefinitionSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return definitionHandler.handle(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDocumentHighlightSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }

        let lspPosition = Position(line: line, character: character)
        let aroPosition = PositionConverter.fromLSP(lspPosition)

        guard let result = state.compilationResult else { return nil }

        // Find what's at this position and return highlight for it
        for analyzed in result.analyzedProgram.featureSets {
            let fs = analyzed.featureSet
            for statement in fs.statements {
                if let aro = statement as? AROStatement {
                    // Check if position is on the action
                    if isPositionInSpan(aroPosition, aro.action.span) {
                        let lspRange = PositionConverter.toLSP(aro.action.span)
                        return [[
                            "range": [
                                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                            ],
                            "kind": 1  // Text
                        ]]
                    }

                    // Check if position is on the result
                    if isPositionInSpan(aroPosition, aro.result.span) {
                        let lspRange = PositionConverter.toLSP(aro.result.span)
                        return [[
                            "range": [
                                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                            ],
                            "kind": 1
                        ]]
                    }

                    // Check if position is on the object
                    if isPositionInSpan(aroPosition, aro.object.noun.span) {
                        let lspRange = PositionConverter.toLSP(aro.object.noun.span)
                        return [[
                            "range": [
                                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
                            ],
                            "kind": 1
                        ]]
                    }
                }
            }
        }

        return nil
    }

    private func isPositionInSpan(_ position: SourceLocation, _ span: SourceSpan) -> Bool {
        if position.line < span.start.line || position.line > span.end.line {
            return false
        }
        if position.line == span.start.line && position.column < span.start.column {
            return false
        }
        if position.line == span.end.line && position.column > span.end.column {
            return false
        }
        return true
    }

    private func handleCompletionSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let context = dict["context"] as? [String: Any]
        let triggerCharacter = context?["triggerCharacter"] as? String
        let lspPosition = Position(line: line, character: character)
        return completionHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult, triggerCharacter: triggerCharacter)
    }

    private func handleReferencesSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return referencesHandler.handle(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDocumentSymbolSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.getSync(uri: uri) else { return nil }
        return documentSymbolHandler.handle(compilationResult: state.compilationResult)
    }

    private func handleWorkspaceSymbolSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let query = dict["query"] as? String else { return nil }
        let allDocuments = documentManager.allSync()
        return workspaceSymbolHandler.handle(query: query, documents: allDocuments)
    }

    private func handleFormattingSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let options = dict["options"] as? [String: Any],
              let state = documentManager.getSync(uri: uri) else { return nil }
        let tabSize = options["tabSize"] as? Int ?? 4
        let insertSpaces = options["insertSpaces"] as? Bool ?? true
        return formattingHandler.handle(content: state.content, options: FormattingOptions(tabSize: tabSize, insertSpaces: insertSpaces))
    }

    private func handlePrepareRenameSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return renameHandler.prepareRename(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleRenameSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let newName = dict["newName"] as? String,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return renameHandler.handle(uri: uri, position: lspPosition, newName: newName, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleFoldingRangeSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.getSync(uri: uri) else { return nil }
        return foldingRangeHandler.handle(compilationResult: state.compilationResult)
    }

    private func handleSemanticTokensSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.getSync(uri: uri) else { return nil }
        return semanticTokensHandler.handle(content: state.content, compilationResult: state.compilationResult)
    }

    private func handleSignatureHelpSync(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return signatureHelpHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleCodeActionSync(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let range = dict["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startChar = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endChar = end["character"] as? Int,
              let state = documentManager.getSync(uri: uri) else { return nil }
        let context = dict["context"] as? [String: Any]
        let diagnostics = context?["diagnostics"] as? [[String: Any]] ?? []
        let startPos = Position(line: startLine, character: startChar)
        let endPos = Position(line: endLine, character: endChar)
        return codeActionHandler.handle(uri: uri, range: (start: startPos, end: endPos), diagnostics: diagnostics, content: state.content, compilationResult: state.compilationResult)
    }

    // MARK: - Message Handling

    /// Extract a complete JSON-RPC message from the buffer
    private func extractMessage(from buffer: inout Data) throws -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        // Parse Content-Length header
        var contentLength: Int?
        for line in headerString.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value)
            }
        }

        guard let length = contentLength else {
            return nil
        }

        let contentStart = headerEnd.upperBound

        // Check if we have enough bytes BEFORE calculating index (to avoid crash)
        let remainingBytes = buffer.distance(from: contentStart, to: buffer.endIndex)
        guard remainingBytes >= length else {
            return nil
        }

        let contentEnd = buffer.index(contentStart, offsetBy: length)

        let messageData = buffer[contentStart..<contentEnd]
        buffer.removeSubrange(..<contentEnd)

        return Data(messageData)
    }

    /// Send a JSON-RPC message
    private func sendMessage(_ data: Data, to output: FileHandle) throws {
        let header = "Content-Length: \(data.count)\r\n\r\n"
        guard let headerData = header.data(using: .utf8) else {
            return
        }

        output.write(headerData)
        output.write(data)
    }

    /// Handle an incoming JSON-RPC message
    private func handleMessage(_ data: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }

        let id = json["id"]
        let params = json["params"]

        log("Handling method: \(method)")

        // Handle the message based on method
        let result: Any?

        switch method {
        case "initialize":
            result = await handleInitialize(params: params)

        case "initialized":
            // Notification, no response needed
            return nil

        case "shutdown":
            result = nil

        case "exit":
            exit(0)

        case "textDocument/didOpen":
            await handleDidOpen(params: params)
            return nil

        case "textDocument/didChange":
            await handleDidChange(params: params)
            return nil

        case "textDocument/didClose":
            await handleDidClose(params: params)
            return nil

        case "textDocument/didSave":
            await handleDidSave(params: params)
            return nil

        case "textDocument/hover":
            result = await handleHover(params: params)

        case "textDocument/definition":
            result = await handleDefinition(params: params)

        case "textDocument/completion":
            result = await handleCompletion(params: params)

        case "textDocument/references":
            result = await handleReferences(params: params)

        case "textDocument/documentSymbol":
            result = await handleDocumentSymbol(params: params)

        case "workspace/symbol":
            result = await handleWorkspaceSymbol(params: params)

        case "textDocument/formatting":
            result = await handleFormatting(params: params)

        case "textDocument/prepareRename":
            result = await handlePrepareRename(params: params)

        case "textDocument/rename":
            result = await handleRename(params: params)

        case "textDocument/foldingRange":
            result = await handleFoldingRange(params: params)

        case "textDocument/semanticTokens/full":
            result = await handleSemanticTokens(params: params)

        case "textDocument/signatureHelp":
            result = await handleSignatureHelp(params: params)

        case "textDocument/codeAction":
            result = await handleCodeAction(params: params)

        case "$/cancelRequest":
            // Cancellation not fully supported yet, just acknowledge
            return nil

        default:
            // Unknown method
            log("Unknown method: \(method)")
            if id != nil {
                return createErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
            }
            return nil
        }

        // Create response if this was a request (has id)
        if let id = id {
            return createSuccessResponse(id: id, result: result)
        }

        return nil
    }

    // MARK: - Initialize

    private func handleInitialize(params: Any?) async -> [String: Any] {
        log("Initialize request received")
        return [
            "capabilities": capabilitiesDict,
            "serverInfo": [
                "name": "aro-lsp",
                "version": "1.1.0"
            ]
        ]
    }

    // MARK: - Document Sync

    private func handleDidOpen(params: Any?) async {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let text = textDocument["text"] as? String,
              let version = textDocument["version"] as? Int else {
            return
        }

        log("Document opened: \(uri)")
        let state = await documentManager.open(uri: uri, content: text, version: version)
        await publishDiagnostics(for: uri, state: state)
    }

    private func handleDidChange(params: Any?) async {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let version = textDocument["version"] as? Int,
              let contentChanges = dict["contentChanges"] as? [[String: Any]] else {
            return
        }

        log("Document changed: \(uri)")

        // Convert content changes to TextDocumentContentChangeEvent
        var changes: [TextDocumentContentChangeEvent] = []
        for change in contentChanges {
            let text = change["text"] as? String ?? ""

            if let rangeDict = change["range"] as? [String: Any],
               let startDict = rangeDict["start"] as? [String: Any],
               let endDict = rangeDict["end"] as? [String: Any],
               let startLine = startDict["line"] as? Int,
               let startChar = startDict["character"] as? Int,
               let endLine = endDict["line"] as? Int,
               let endChar = endDict["character"] as? Int {
                // Incremental change
                let range = LSPRange(
                    start: Position(line: startLine, character: startChar),
                    end: Position(line: endLine, character: endChar)
                )
                changes.append(TextDocumentContentChangeEvent(range: range, rangeLength: nil, text: text))
            } else {
                // Full content change
                changes.append(TextDocumentContentChangeEvent(range: nil, rangeLength: nil, text: text))
            }
        }

        if let state = await documentManager.applyChanges(uri: uri, changes: changes, version: version) {
            await publishDiagnostics(for: uri, state: state)
        }
    }

    private func handleDidClose(params: Any?) async {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return
        }

        log("Document closed: \(uri)")
        await documentManager.close(uri: uri)
        // Clear diagnostics
        await publishDiagnostics(for: uri, diagnostics: [])
    }

    private func handleDidSave(params: Any?) async {
        // Re-publish diagnostics on save
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return
        }

        log("Document saved: \(uri)")
        if let state = await documentManager.get(uri: uri) {
            await publishDiagnostics(for: uri, state: state)
        }
    }

    // MARK: - LSP Features

    private func handleHover(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return hoverHandler.handle(
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleDefinition(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return definitionHandler.handle(
            uri: uri,
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleCompletion(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let context = dict["context"] as? [String: Any]
        let triggerCharacter = context?["triggerCharacter"] as? String

        let lspPosition = Position(line: line, character: character)
        return completionHandler.handle(
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult,
            triggerCharacter: triggerCharacter
        )
    }

    private func handleReferences(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return referencesHandler.handle(
            uri: uri,
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleDocumentSymbol(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        return documentSymbolHandler.handle(compilationResult: state.compilationResult)
    }

    private func handleWorkspaceSymbol(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let query = dict["query"] as? String else {
            return nil
        }

        let allDocuments = await documentManager.all()
        return workspaceSymbolHandler.handle(query: query, documents: allDocuments)
    }

    private func handleFormatting(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let options = dict["options"] as? [String: Any] else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let tabSize = options["tabSize"] as? Int ?? 4
        let insertSpaces = options["insertSpaces"] as? Bool ?? true

        return formattingHandler.handle(
            content: state.content,
            options: FormattingOptions(tabSize: tabSize, insertSpaces: insertSpaces)
        )
    }

    private func handlePrepareRename(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return renameHandler.prepareRename(
            uri: uri,
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleRename(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let newName = dict["newName"] as? String else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return renameHandler.handle(
            uri: uri,
            position: lspPosition,
            newName: newName,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleFoldingRange(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        return foldingRangeHandler.handle(compilationResult: state.compilationResult)
    }

    private func handleSemanticTokens(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        return semanticTokensHandler.handle(
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleSignatureHelp(params: Any?) async -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let lspPosition = Position(line: line, character: character)
        return signatureHelpHandler.handle(
            position: lspPosition,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    private func handleCodeAction(params: Any?) async -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let range = dict["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startChar = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endChar = end["character"] as? Int else {
            return nil
        }

        guard let state = await documentManager.get(uri: uri) else {
            return nil
        }

        let context = dict["context"] as? [String: Any]
        let diagnostics = context?["diagnostics"] as? [[String: Any]] ?? []

        let startPos = Position(line: startLine, character: startChar)
        let endPos = Position(line: endLine, character: endChar)

        return codeActionHandler.handle(
            uri: uri,
            range: (start: startPos, end: endPos),
            diagnostics: diagnostics,
            content: state.content,
            compilationResult: state.compilationResult
        )
    }

    // MARK: - Diagnostics Publishing

    private func publishDiagnostics(for uri: String, state: DocumentManager.DocumentState) async {
        guard let result = state.compilationResult else {
            await publishDiagnostics(for: uri, diagnostics: [])
            return
        }

        let lspDiagnostics = diagnosticsHandler.convert(result.diagnostics)
        await publishDiagnostics(for: uri, diagnostics: lspDiagnostics)
    }

    private func publishDiagnostics(for uri: String, diagnostics: [[String: Any]]) async {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": uri,
                "diagnostics": diagnostics
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: notification) {
            try? sendMessage(data, to: FileHandle.standardOutput)
        }
    }

    // MARK: - Response Helpers

    private func createSuccessResponse(id: Any?, result: Any?) -> Data? {
        var response: [String: Any] = [
            "jsonrpc": "2.0"
        ]

        if let id = id {
            response["id"] = id
        }

        if let result = result {
            response["result"] = result
        } else {
            response["result"] = NSNull()
        }

        return try? JSONSerialization.data(withJSONObject: response)
    }

    private func createErrorResponse(id: Any?, code: Int, message: String) -> Data? {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]

        if let id = id {
            response["id"] = id
        }

        return try? JSONSerialization.data(withJSONObject: response)
    }
}

#endif
