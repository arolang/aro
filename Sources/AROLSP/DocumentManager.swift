// ============================================================
// DocumentManager.swift
// AROLSP - Document State Management
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Manages the state of open documents.
///
/// ## didChange debounce (#352)
///
/// `textDocument/didChange` used to run a synchronous
/// `Compiler.compile(content)` on **every** edit — a full parse +
/// semantic analysis per keystroke. On a 1000-line file that is a
/// visible stall while typing.
///
/// Now `applyChanges` (and the full-content `update`) update the
/// stored **text immediately** — so hover / completion / signature
/// help read fresh text — but the expensive compile is *scheduled*
/// to run only after a short quiet period (`debounceInterval`). Any
/// pending compile for the same URI is cancelled when a newer edit
/// arrives, so a burst of keystrokes collapses to a single compile
/// of the final text.
///
/// `open` still compiles **synchronously** — the first diagnostics
/// for a freshly opened file should not wait for a keystroke.
///
/// While a compile is pending the document keeps its **previous**
/// `compilationResult`, so consumers that read the "last good AST"
/// never see `nil` mid-edit; the stale result is replaced wholesale
/// once the debounced compile finishes.
public final class DocumentManager: @unchecked Sendable {
    private let lock = NSLock()

    /// Default quiet period before a debounced compile runs. Exposed
    /// so tests (and callers wanting a different feel) can reference
    /// it; overridable via `init(debounceInterval:)`.
    public static let debounceInterval: Duration = .milliseconds(150)

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
    ///
    /// During the debounce window (#352) `content` is already the
    /// latest text while `compilationResult` may still reflect the
    /// text from before the in-flight edit — it is never `nil` just
    /// because a compile is pending.
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

    /// The generation counter for each URI's most recently scheduled
    /// debounced compile. A scheduled `Task` only commits its result
    /// if its captured generation still matches — i.e. no newer edit
    /// (which bumped the counter and started its own task) has
    /// arrived. Task-cancellation is the primary cancel mechanism;
    /// the counter closes the race where a task wakes from
    /// `Task.sleep` just as a newer edit lands.
    private var generations: [DocumentUri: Int] = [:]

    /// In-flight debounced compile tasks, keyed by URI, so a newer
    /// edit can cancel the previous one.
    private var pendingCompiles: [DocumentUri: Task<Void, Never>] = [:]

    private let debounceInterval: Duration

    /// Invoked after a *debounced* compile commits a new
    /// `DocumentState`. The server uses this to publish diagnostics
    /// for the just-compiled text. Not called for the synchronous
    /// `open` / `update` paths — callers of those already hold the
    /// returned state and publish directly.
    private let onCompile: (@Sendable (DocumentState) -> Void)?

    // MARK: - Initialization

    public init(
        debounceInterval: Duration = DocumentManager.debounceInterval,
        onCompile: (@Sendable (DocumentState) -> Void)? = nil
    ) {
        self.debounceInterval = debounceInterval
        self.onCompile = onCompile
    }

    // MARK: - Document Operations

    // All public mutation / query methods now go through `lock`
    // (#356 unification). The previous "non-Sync" variants
    // omitted the lock entirely — a real race when the LSP runs
    // multi-threaded request dispatch. The "Sync" variants
    // remain as thin forwarders so existing callers don't have
    // to migrate in this MR.

    /// Open a document. Compiles **synchronously** — first diagnostics
    /// should not wait for a keystroke.
    public func open(uri: DocumentUri, content: String, version: Int) -> DocumentState {
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        lock.lock()
        // A fresh open supersedes any pending debounced compile.
        cancelPendingLocked(uri: uri)
        documents[uri] = state
        lock.unlock()
        return state
    }

    /// Update a document with full content replacement. Compiles
    /// synchronously (used by the full-sync path / tests). Supersedes
    /// any pending debounced compile.
    public func update(uri: DocumentUri, content: String, version: Int) -> DocumentState? {
        let result = Compiler.compile(content)
        let state = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )
        lock.lock()
        cancelPendingLocked(uri: uri)
        documents[uri] = state
        lock.unlock()
        return state
    }

    /// Apply incremental changes to a document.
    ///
    /// The **text** is updated immediately and returned so cursor-driven
    /// handlers see the latest content. The expensive compile is
    /// deferred: it runs only after `debounceInterval` of quiet, and a
    /// newer edit cancels the pending compile. The previous
    /// `compilationResult` is carried forward until the debounced
    /// compile replaces it.
    ///
    /// The returned state reflects the new text but the *previous*
    /// compilation result. When the debounced compile eventually runs
    /// it invokes `onCompile` with the recompiled state.
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
        let previousResult = state.compilationResult
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

        // Update the stored text immediately, carrying the previous
        // (stale-but-valid) compilation result forward so consumers
        // that read the last-good AST never observe nil mid-edit.
        let interimState = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: previousResult
        )

        lock.lock()
        documents[uri] = interimState
        // Bump the generation and cancel any in-flight compile; only
        // the newest scheduled task commits its result.
        let generation = (generations[uri] ?? 0) + 1
        generations[uri] = generation
        pendingCompiles[uri]?.cancel()

        let interval = debounceInterval
        let task = Task { [weak self] in
            guard let self else { return }
            // Wait out the quiet period; a newer edit cancels us.
            do {
                try await Task.sleep(for: interval)
            } catch {
                return // cancelled
            }
            if Task.isCancelled { return }
            self.runDebouncedCompile(
                uri: uri,
                content: content,
                version: version,
                generation: generation
            )
        }
        pendingCompiles[uri] = task
        lock.unlock()

        return interimState
    }

    /// Compile `content` and commit the result iff this is still the
    /// newest scheduled compile for `uri`. Invoked off the request
    /// path by the debounce task.
    private func runDebouncedCompile(
        uri: DocumentUri,
        content: String,
        version: Int,
        generation: Int
    ) {
        // Compile outside the lock — it's the expensive part.
        let result = Compiler.compile(content)
        let newState = DocumentState(
            uri: uri,
            content: content,
            version: version,
            compilationResult: result
        )

        lock.lock()
        // Discard if a newer edit superseded us, or the doc closed.
        guard generations[uri] == generation, documents[uri] != nil else {
            lock.unlock()
            return
        }
        documents[uri] = newState
        pendingCompiles[uri] = nil
        let callback = onCompile
        lock.unlock()

        callback?(newState)
    }

    /// Cancel and forget any pending debounced compile for `uri`.
    /// Caller must hold `lock`.
    private func cancelPendingLocked(uri: DocumentUri) {
        pendingCompiles[uri]?.cancel()
        pendingCompiles[uri] = nil
        generations[uri] = (generations[uri] ?? 0) + 1
    }

    /// Close a document
    public func close(uri: DocumentUri) {
        lock.lock(); defer { lock.unlock() }
        cancelPendingLocked(uri: uri)
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
