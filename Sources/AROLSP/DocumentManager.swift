// ============================================================
// DocumentManager.swift
// AROLSP - Document State Management
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Manages the state of open documents
public final class DocumentManager: @unchecked Sendable {
    private let lock = NSLock()

    /// State of a single document
    public struct DocumentState: Sendable {
        public let uri: DocumentUri
        public let content: String
        public let version: Int
        public let compilationResult: CompilationResult?

        public init(
            uri: DocumentUri,
            content: String,
            version: Int,
            compilationResult: CompilationResult? = nil
        ) {
            self.uri = uri
            self.content = content
            self.version = version
            self.compilationResult = compilationResult
        }
    }

    // MARK: - Properties

    private var documents: [DocumentUri: DocumentState] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Document Operations

    /// Open a document
    public func open(uri: DocumentUri, content: String, version: Int) -> DocumentState {
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        documents[uri] = state
        return state
    }

    /// Update a document with full content replacement
    public func update(uri: DocumentUri, content: String, version: Int) -> DocumentState? {
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        documents[uri] = state
        return state
    }

    /// Apply incremental changes to a document
    public func applyChanges(
        uri: DocumentUri,
        changes: [TextDocumentContentChangeEvent],
        version: Int
    ) -> DocumentState? {
        guard let state = documents[uri] else { return nil }

        var content = state.content

        for change in changes {
            if let range = change.range {
                // Incremental change
                let lspRange = range
                let startOffset = PositionConverter.calculateOffset(lspRange.start, in: content)
                let endOffset = PositionConverter.calculateOffset(lspRange.end, in: content)

                let startIndex = content.index(content.startIndex, offsetBy: startOffset)
                let endIndex = content.index(content.startIndex, offsetBy: min(endOffset, content.count))

                content.replaceSubrange(startIndex..<endIndex, with: change.text)
            } else {
                // Full content replacement
                content = change.text
            }
        }

        let result = Compiler.compile(content)
        let newState = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        documents[uri] = newState
        return newState
    }

    /// Close a document
    public func close(uri: DocumentUri) {
        documents.removeValue(forKey: uri)
    }

    /// Get document state
    public func get(uri: DocumentUri) -> DocumentState? {
        documents[uri]
    }

    /// Get all open documents
    public func all() -> [DocumentUri: DocumentState] {
        documents
    }

    /// Check if a document is open
    public func isOpen(uri: DocumentUri) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return documents[uri] != nil
    }

    // MARK: - Synchronous Operations

    /// Open a document synchronously
    public func openSync(uri: DocumentUri, content: String, version: Int) -> DocumentState {
        lock.lock()
        defer { lock.unlock() }
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        documents[uri] = state
        return state
    }

    /// Apply changes synchronously
    public func applyChangesSync(
        uri: DocumentUri,
        changes: [TextDocumentContentChangeEvent],
        version: Int
    ) -> DocumentState? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = documents[uri] else { return nil }

        var content = state.content

        for change in changes {
            if let range = change.range {
                let lspRange = range
                let startOffset = PositionConverter.calculateOffset(lspRange.start, in: content)
                let endOffset = PositionConverter.calculateOffset(lspRange.end, in: content)

                let startIndex = content.index(content.startIndex, offsetBy: startOffset)
                let endIndex = content.index(content.startIndex, offsetBy: min(endOffset, content.count))

                content.replaceSubrange(startIndex..<endIndex, with: change.text)
            } else {
                content = change.text
            }
        }

        let result = Compiler.compile(content)
        let newState = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        documents[uri] = newState
        return newState
    }

    /// Close document synchronously
    public func closeSync(uri: DocumentUri) {
        lock.lock()
        defer { lock.unlock() }
        documents.removeValue(forKey: uri)
    }

    /// Get document synchronously
    public func getSync(uri: DocumentUri) -> DocumentState? {
        lock.lock()
        defer { lock.unlock() }
        return documents[uri]
    }

    /// Get all documents synchronously
    public func allSync() -> [DocumentUri: DocumentState] {
        lock.lock()
        defer { lock.unlock() }
        return documents
    }
}

#endif
