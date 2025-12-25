// ============================================================
// AROLanguageServer.swift
// AROLSP - Main Language Server Implementation
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

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

    // MARK: - Initialization

    public init() {
        self.documentManager = DocumentManager()
        self.hoverHandler = HoverHandler()
        self.definitionHandler = DefinitionHandler()
        self.completionHandler = CompletionHandler()
        self.referencesHandler = ReferencesHandler()
        self.documentSymbolHandler = DocumentSymbolHandler()
        self.diagnosticsHandler = DiagnosticsHandler()
    }

    // MARK: - Server Capabilities

    /// Server capabilities as a dictionary for the initialize response
    private var capabilitiesDict: [String: Any] {
        [
            "textDocumentSync": [
                "openClose": true,
                "change": 1,  // Full sync
                "save": ["includeText": true]
            ],
            "hoverProvider": true,
            "completionProvider": [
                "triggerCharacters": ["<", ":", "."],
                "resolveProvider": false
            ],
            "definitionProvider": true,
            "referencesProvider": true,
            "documentSymbolProvider": true
        ]
    }

    // MARK: - Stdio Transport

    /// Run the language server using stdio transport
    public func runStdio() async throws {
        let input = FileHandle.standardInput
        let output = FileHandle.standardOutput

        var buffer = Data()

        while true {
            // Read data from stdin
            let availableData = input.availableData
            if availableData.isEmpty {
                // EOF
                break
            }
            buffer.append(availableData)

            // Try to parse complete messages
            while let message = try extractMessage(from: &buffer) {
                let response = await handleMessage(message)
                if let response = response {
                    try sendMessage(response, to: output)
                }
            }
        }
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
        let contentEnd = buffer.index(contentStart, offsetBy: length)

        guard contentEnd <= buffer.endIndex else {
            return nil
        }

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

        default:
            // Unknown method
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
        return [
            "capabilities": capabilitiesDict
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

        // For full sync, just take the last change
        if let lastChange = contentChanges.last,
           let text = lastChange["text"] as? String {
            if let state = await documentManager.update(uri: uri, content: text, version: version) {
                await publishDiagnostics(for: uri, state: state)
            }
        }
    }

    private func handleDidClose(params: Any?) async {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else {
            return
        }

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
