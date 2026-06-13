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

    /// State of a single document.
    ///
    /// `compilationResult` is the **shared** parse + analyze
    /// output for the current `content`. Handlers (completion,
    /// references, hover, signature-help, …) must read from it
    /// instead of re-parsing or re-running semantic analysis on
    /// the raw \`content\` — doing so on every keystroke is what
    /// the cache is for (#358). The state is replaced wholesale
    /// on \`update\` / \`applyChanges\`; consumers that hold a
    /// reference to a stale \`DocumentState\` are reading the
    /// snapshot they were given and need to re-fetch from the
    /// manager to see the latest.
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

    // All public mutation / query methods now go through `lock`
    // (#356 unification). The previous "non-Sync" variants
    // omitted the lock entirely — a real race when the LSP runs
    // multi-threaded request dispatch. The "Sync" variants
    // remain as thin forwarders so existing callers don't have
    // to migrate in this MR.

    /// Open a document
    public func open(uri: DocumentUri, content: String, version: Int) -> DocumentState {
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
        documents[uri] = state
        return state
    }

    /// Apply incremental changes to a document
    public func applyChanges(
        uri: DocumentUri,
        changes: [TextDocumentContentChangeEvent],
        version: Int
    ) -> DocumentState? {
        lock.lock()
        guard let state = documents[uri] else {
            lock.unlock()
            return nil
        }
        var content = state.content
        lock.unlock()

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
        lock.lock(); defer { lock.unlock() }
        documents[uri] = newState
        return newState
    }

    /// Close a document
    public func close(uri: DocumentUri) {
        lock.lock(); defer { lock.unlock() }
        documents.removeValue(forKey: uri)
    }

    /// Get document state
    public func get(uri: DocumentUri) -> DocumentState? {
        lock.lock(); defer { lock.unlock() }
        return documents[uri]
    }

    /// Get all open documents
    public func all() -> [DocumentUri: DocumentState] {
        lock.lock(); defer { lock.unlock() }
        return documents
    }

    /// Check if a document is open
    public func isOpen(uri: DocumentUri) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return documents[uri] != nil
    }

    // MARK: - Legacy "Sync" Aliases (#356)
    //
    // Pre-unification the *Sync variants were the only
    // thread-safe ones. The main methods above now take the
    // lock too, so these are thin forwarders kept around for
    // source compatibility. Migrate call sites to the plain
    // names in follow-ups.

    public func openSync(uri: DocumentUri, content: String, version: Int) -> DocumentState {
        open(uri: uri, content: content, version: version)
    }

    public func applyChangesSync(
        uri: DocumentUri,
        changes: [TextDocumentContentChangeEvent],
        version: Int
    ) -> DocumentState? {
        applyChanges(uri: uri, changes: changes, version: version)
    }

    public func closeSync(uri: DocumentUri) {
        close(uri: uri)
    }

    public func getSync(uri: DocumentUri) -> DocumentState? {
        get(uri: uri)
    }

    public func allSync() -> [DocumentUri: DocumentState] {
        all()
    }
}

#endif
