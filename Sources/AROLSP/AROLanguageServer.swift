// ============================================================
// AROLanguageServer.swift
// AROLSP - Main Language Server Implementation
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import ARORuntime
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
    private let inlayHintHandler: InlayHintHandler

    private let debugMode: Bool

    /// Workspace folders captured during `initialize`. Used by the catalog to
    /// load plugins from `<workspace>/Plugins/` so plugin-supplied actions and
    /// qualifiers show up in completion/hover.
    private let workspaceState = WorkspaceState()

    /// Thread-safe workspace tracking. The LSP class is `final class Sendable`,
    /// so mutation goes through this serialised box.
    /// Internal rather than private so the tests can drive the real scan and
    /// invalidation instead of only the `declaredActionsProvider` seam.
    final class WorkspaceState: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [URL] = []

        /// `Application.<Name>` declarations across the whole workspace, or
        /// `nil` when they need rescanning.
        ///
        /// Cached because it is consulted on every compile — which is every
        /// keystroke after the debounce — while the answer only changes when a
        /// file is added, removed, or has its `Action` header edited.
        /// `UserActionRegistry.declared(inFiles:)` is a parse-only scan, so a
        /// rebuild is cheap, but doing it per keystroke would not be.
        private var declaredActions: UserActionRegistry?

        /// The contract's per-route body limits, keyed by the directory of the
        /// file being edited.
        ///
        /// Cached for the same reason `declaredActions` is: the inlay-hint
        /// handler asks on every viewport scroll, and answering meant walking
        /// up to six directories × three filenames of `fileExists` and then
        /// parsing `openapi.yaml` from disk (GitLab #720). The contract's
        /// modification date is kept with the answer, so an edit to the
        /// contract is picked up without waiting for an invalidation signal.
        private var bodyLimits: [String: BodyLimitsEntry] = [:]

        private struct BodyLimitsEntry {
            let contract: URL?
            let modified: Date?
            let limits: RouteBodyLimits
        }

        func setRoots(_ urls: [URL]) {
            lock.lock(); defer { lock.unlock() }
            roots = urls
            declaredActions = nil
            bodyLimits = [:]
        }

        var allRoots: [URL] {
            lock.lock(); defer { lock.unlock() }
            return roots
        }

        /// Drop the caches; the next compile rescans.
        ///
        /// The body limits go too: a `didSave` or a watched-file change may
        /// have created an `openapi.yaml` where the last walk found none, and
        /// a cached "no contract here" answer has no modification date to
        /// notice that with.
        func invalidateDeclaredActions() {
            lock.lock(); defer { lock.unlock() }
            declaredActions = nil
            bodyLimits = [:]
        }

        /// The per-route body limits that apply to `file`.
        func currentBodyLimits(near file: URL?) -> RouteBodyLimits {
            let key = file?.deletingLastPathComponent().path ?? ""

            lock.lock()
            let cached = bodyLimits[key]
            let currentRoots = roots
            lock.unlock()

            if let cached, let contract = cached.contract,
               let modified = try? FileManager.default.attributesOfItem(
                   atPath: contract.path)[.modificationDate] as? Date,
               modified == cached.modified {
                return cached.limits
            }
            // A cached answer of "no contract" stands until something
            // invalidates it — there is no file to date-stamp.
            if let cached, cached.contract == nil { return cached.limits }

            let contract = RouteBodyLimits.contract(near: file, roots: currentRoots)
            let limits = contract.flatMap { RouteBodyLimits.load(from: $0) } ?? .empty
            let modified = contract.flatMap {
                try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date
            }

            lock.lock()
            bodyLimits[key] = BodyLimitsEntry(contract: contract, modified: modified, limits: limits)
            lock.unlock()
            return limits
        }

        /// The workspace's declared actions, scanning on first use.
        ///
        /// `nil` with no roots — an editor opened on a single loose file has
        /// no application to speak for, and the analyser's own diagnostic
        /// already says only this file was analysed.
        func currentDeclaredActions() -> UserActionRegistry? {
            lock.lock()
            let cached = declaredActions
            let currentRoots = roots
            lock.unlock()

            if let cached { return cached }
            guard !currentRoots.isEmpty else { return nil }

            let files = currentRoots.flatMap { Self.aroFiles(under: $0) }
            guard !files.isEmpty else { return nil }
            let scanned = UserActionRegistry.declared(inFiles: files)

            lock.lock()
            declaredActions = scanned
            lock.unlock()
            return scanned
        }

        /// Every `.aro` file under `root`, skipping the directories an
        /// application's sources never live in.
        private static func aroFiles(under root: URL) -> [URL] {
            let skipped: Set<String> = [".build", ".git", "node_modules", ".swiftpm"]
            guard let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var found: [URL] = []
            for case let url as URL in walker {
                if url.hasDirectoryPath {
                    if skipped.contains(url.lastPathComponent) { walker.skipDescendants() }
                    continue
                }
                if url.pathExtension == "aro" { found.append(url) }
            }
            return found
        }
    }

    // MARK: - Initialization

    public init(debug: Bool = false) {
        self.debugMode = debug
        // The document manager debounces didChange recompiles (#352):
        // it updates stored text immediately but defers the compile,
        // then calls this closure once the debounced compile lands so
        // we can publish fresh diagnostics. `open` still compiles
        // synchronously and is published inline (see handleDidOpen).
        let diagnostics = DiagnosticsHandler()
        self.diagnosticsHandler = diagnostics
        self.documentManager = DocumentManager { state in
            AROLanguageServer.publishDiagnostics(
                for: state.uri,
                state: state,
                diagnosticsHandler: diagnostics
            )
        }
        // The manager asks for the application's declared actions on every
        // compile, so a cross-file `Application.<Name>` call resolves in the
        // editor exactly as it does under `aro check` (GitLab #589).
        let workspace = workspaceState
        self.documentManager.declaredActionsProvider = { workspace.currentDeclaredActions() }

        self.hoverHandler = HoverHandler()
        self.definitionHandler = DefinitionHandler()
        self.completionHandler = CompletionHandler()
        self.referencesHandler = ReferencesHandler()
        self.documentSymbolHandler = DocumentSymbolHandler()
        self.renameHandler = RenameHandler()
        self.workspaceSymbolHandler = WorkspaceSymbolHandler()
        self.formattingHandler = FormattingHandler()
        self.foldingRangeHandler = FoldingRangeHandler()
        self.semanticTokensHandler = SemanticTokensHandler()
        self.signatureHelpHandler = SignatureHelpHandler()
        self.codeActionHandler = CodeActionHandler()
        self.inlayHintHandler = InlayHintHandler()
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
            ],
            "inlayHintProvider": [
                "resolveProvider": false
            ]
        ]
    }

    // MARK: - Debug Logging

    private func log(_ message: String) {
        if debugMode {
            FileHandle.standardError.write(Data("[\(timestamp())] \(message)\n".utf8))
        }
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Stdio Transport

    /// Run the language server over stdio. The only transport.
    ///
    /// There used to be two: this blocking POSIX-read loop and an `async`
    /// twin, each with its own message decoder, its own pair of dispatch
    /// tables and its own full set of handlers — some 550 lines duplicated
    /// almost verbatim. Nothing ever called the async one. `aro lsp` is the
    /// single entry point every client uses (the VS Code and IntelliJ
    /// extensions and SOLARO all spawn it), and `LSPCommand` has only ever
    /// called this loop, so the async half was answering no messages at all
    /// while looking exactly as authoritative as the half that was
    /// (GitLab #736).
    ///
    /// Duplication like that does not stay duplicated. The dead half had
    /// quietly grown the better `didOpen`, `didClose` and `didSave`
    /// behaviour, which the live half therefore did not have; those are
    /// ported into the handlers below, and this file now has one place
    /// where each of them can be got wrong.
    ///
    /// `nonisolated` is redundant today — the class carries no actor
    /// isolation — but it is the property the deletion was meant to
    /// preserve: an async message loop, if anyone wants one later, wraps
    /// this transport rather than reimplementing the handlers, and putting
    /// the server on a global actor would now fail to compile here instead
    /// of silently making the handlers unreachable from `async` code.
    nonisolated public func runStdio() {
        // Ignore signals that can crash the process when spawned by VSCode
        signal(SIGPIPE, SIG_IGN)

        log("ARO Language Server starting...")

        // Use a simple blocking read loop on the main thread
        var buffer = Data()
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
                if let response = handleMessage(message) {
                    log("Sending response: \(String(data: response.prefix(200), encoding: .utf8) ?? "...")")
                    try? sendMessage(response, to: output)
                }
            }
        }
    }

    /// Answer one JSON-RPC message, returning the response to write back
    /// (or `nil` for a notification, which is never answered).
    ///
    /// Dispatch is table-driven (see ``requestHandlers`` and
    /// ``notificationHandlers``): the method name is looked up in the
    /// appropriate table and the stored closure is invoked. A handful of
    /// lifecycle methods (`initialize`, `initialized`, `shutdown`, `exit`)
    /// carry special return/side-effect semantics and are handled inline.
    ///
    /// Nothing here suspends, so an async loop can call it directly; see
    /// ``runStdio()`` on why that matters.
    ///
    /// Internal rather than private so the tests can drive real JSON-RPC
    /// through the real tables, which is the level the two transports
    /// diverged at.
    nonisolated func handleMessage(_ data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return nil
        }

        let id = json["id"]
        let params = json["params"]

        log("Handling method: \(method)")

        // Lifecycle methods with bespoke semantics.
        switch method {
        case "initialized":
            // Client is ready; load workspace plugins now so subsequent
            // completion/hover sees plugin-provided actions and qualifiers.
            loadWorkspacePluginsAsync()
            return nil
        case "exit":
            exit(0)
        case "shutdown":
            // A request that always resolves to a null result.
            return id.map { createSuccessResponse(id: $0, result: nil) } ?? nil
        default:
            break
        }

        // Notifications: handled for side effects, never answered.
        if let handler = Self.notificationHandlers[method] {
            handler(self, params)
            return nil
        }

        // Requests: produce a result that is wrapped in a success response
        // when the message carries an id.
        if let handler = Self.requestHandlers[method] {
            let result = handler(self, params)
            if let id = id {
                return createSuccessResponse(id: id, result: result)
            }
            return nil
        }

        log("Unknown method: \(method)")
        if id != nil {
            return createErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
        return nil
    }

    // MARK: - Dispatch Tables

    /// Request methods the server answers. Each closure maps the raw `params`
    /// to a JSON-serialisable result (or `nil`). The result is wrapped in a
    /// JSON-RPC success response by ``handleMessage``.
    /// Built once for the process, not once per message.
    ///
    /// These were computed properties, so every JSON-RPC message — every
    /// keystroke's `didChange`, every viewport scroll's `inlayHint` — built a
    /// 16-entry dictionary of freshly allocated closures just to look one
    /// name up in it (GitLab #720). The table is a property of the protocol,
    /// not of a server instance, so it is `static` and the instance arrives as
    /// an argument; that also keeps the closures from capturing `self`, which
    /// a stored `let` on a class would have made a retain cycle.
    private static let requestHandlers: [String: @Sendable (AROLanguageServer, Any?) -> Any?] = [
        "initialize": { $0.handleInitialize(params: $1) },
        "textDocument/hover": { $0.handleHover(params: $1) },
        "textDocument/definition": { $0.handleDefinition(params: $1) },
        "textDocument/documentHighlight": { $0.handleDocumentHighlight(params: $1) },
        "textDocument/completion": { $0.handleCompletion(params: $1) },
        "textDocument/references": { $0.handleReferences(params: $1) },
        "textDocument/documentSymbol": { $0.handleDocumentSymbol(params: $1) },
        "workspace/symbol": { $0.handleWorkspaceSymbol(params: $1) },
        "textDocument/formatting": { $0.handleFormatting(params: $1) },
        "textDocument/prepareRename": { $0.handlePrepareRename(params: $1) },
        "textDocument/rename": { $0.handleRename(params: $1) },
        "textDocument/foldingRange": { $0.handleFoldingRange(params: $1) },
        "textDocument/semanticTokens/full": { $0.handleSemanticTokens(params: $1) },
        "textDocument/signatureHelp": { $0.handleSignatureHelp(params: $1) },
        "textDocument/codeAction": { $0.handleCodeAction(params: $1) },
        "textDocument/inlayHint": { $0.handleInlayHint(params: $1) }
    ]

    /// Notification methods the server acts on. Handled for their side
    /// effects; no response is ever produced.
    private static let notificationHandlers: [String: @Sendable (AROLanguageServer, Any?) -> Void] = [
        "textDocument/didOpen": { $0.handleDidOpen(params: $1) },
        "textDocument/didChange": { $0.handleDidChange(params: $1) },
        "textDocument/didClose": { $0.handleDidClose(params: $1) },
        "textDocument/didSave": { $0.handleDidSave(params: $1) },
        // A file created or deleted outside the editor changes which
        // actions the workspace declares, and no `didOpen`/`didSave`
        // announces it (GitLab #589). Clients only send this when they
        // watch files, so it is a bonus signal, not the primary one.
        "workspace/didChangeWatchedFiles": { server, _ in
            server.workspaceState.invalidateDeclaredActions()
        },
        // A deliberate no-op rather than an omission: requests are answered
        // on the read loop's own thread, so by the time a cancellation
        // arrives the request it names has already been answered. Listed
        // here so it is acknowledged instead of falling through to
        // "Method not found".
        "$/cancelRequest": { _, _ in }
    ]

    // MARK: - Handlers

    private func handleInitialize(params: Any?) -> [String: Any] {
        log("Initialize request received")
        captureWorkspaceRoots(from: params)
        return [
            "capabilities": capabilitiesDict,
            "serverInfo": [
                "name": "aro-lsp",
                "version": "1.3.0"
            ]
        ]
    }

    /// Read `rootUri` and `workspaceFolders[].uri` from the LSP `initialize`
    /// params and stash them. Used later to discover `<workspace>/Plugins/`.
    private func captureWorkspaceRoots(from params: Any?) {
        var roots: [URL] = []
        if let dict = params as? [String: Any] {
            if let rootUri = dict["rootUri"] as? String, let url = uriToURL(rootUri) {
                roots.append(url)
            } else if let rootPath = dict["rootPath"] as? String {
                roots.append(URL(fileURLWithPath: rootPath))
            }
            if let folders = dict["workspaceFolders"] as? [[String: Any]] {
                for folder in folders {
                    if let uri = folder["uri"] as? String, let url = uriToURL(uri) {
                        roots.append(url)
                    }
                }
            }
        }
        // Deduplicate while preserving order
        var seen: Set<URL> = []
        let unique = roots.filter { seen.insert($0.standardizedFileURL).inserted }
        workspaceState.setRoots(unique)
        if !unique.isEmpty {
            log("Workspace roots: \(unique.map { $0.path })")
        }
        // Quick structural sanity check (#371). Warn — but don't
        // refuse — when the workspace doesn't look like an ARO
        // application. The most common wrong-folder mistakes are
        // (a) opening the project's parent directory, or (b)
        // opening a docs / Examples directory; both produce
        // confusing diagnostics downstream.
        for root in unique {
            validateWorkspaceStructure(root)
        }
    }

    private func validateWorkspaceStructure(_ root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            log("warning: workspace root '\(root.path)' is not readable")
            return
        }
        let names = entries.map { $0.lastPathComponent.lowercased() }
        let hasAro = names.contains { $0.hasSuffix(".aro") }
        let hasOpenAPI = names.contains("openapi.yaml") || names.contains("openapi.yml")
        let hasSources = names.contains("sources")
        if !hasAro && !hasOpenAPI && !hasSources {
            log("warning: workspace root '\(root.path)' contains no .aro files, openapi.yaml, or sources/ subdirectory — diagnostics will be empty until a recognised ARO project layout is present")
        }
    }

    /// Decode an LSP `file://` URI to a `URL`, accepting both the canonical
    /// `file:///path` form and the bare path form some clients send.
    private func uriToURL(_ uri: String) -> URL? {
        if uri.hasPrefix("file://") {
            return URL(string: uri)
        }
        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri)
        }
        return nil
    }

    /// Load plugins from each workspace `Plugins/` directory into the shared
    /// AROCatalog so completion/hover sees plugin-provided actions and qualifiers.
    /// Runs off the calling thread so `initialized` can return immediately.
    private func loadWorkspacePluginsAsync() {
        let roots = workspaceState.allRoots
        guard !roots.isEmpty else { return }
        let debug = self.debugMode

        Task.detached {
            for root in roots {
                let loaded = await AROCatalog.shared.loadPluginsFromWorkspace(root)
                if loaded && debug {
                    FileHandle.standardError.write(Data("[aro-lsp] Loaded plugins from \(root.path)/Plugins\n".utf8))
                }
            }
        }
    }

    /// Compile the newly opened document and publish its diagnostics.
    ///
    /// The publish is the part that used to be missing on this path
    /// (GitLab #736): the handler took the compiled state back from the
    /// manager and threw it away. `DocumentManager` only calls its
    /// `onCompile` callback for the *debounced* compile — `open` returns its
    /// result to the caller instead, precisely so the caller can publish it
    /// — so opening a file with an error in it produced no squiggle at all
    /// until the first keystroke. The deleted async handler had it right; it
    /// just was not the handler anyone reached.
    private func handleDidOpen(params: Any?) {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let text = textDocument["text"] as? String,
              let version = textDocument["version"] as? Int else { return }
        log("Document opened: \(uri)")
        let state = documentManager.open(uri: uri, content: text, version: version)
        publishDiagnostics(for: uri, state: state)
    }

    private func handleDidChange(params: Any?) {
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
        // #352: `applyChanges` updates the stored text immediately but
        // *debounces* the compile, and the returned state therefore carries
        // the new text with the previous compilation result. Fresh
        // diagnostics are published by the manager's `onCompile` callback
        // once the debounced compile lands; publishing the interim state
        // here would re-emit the stale diagnostics on every keystroke, so
        // this is the one document notification that deliberately does not
        // publish.
        _ = documentManager.applyChanges(uri: uri, changes: changes, version: version)
    }

    /// Forget the document and clear its diagnostics.
    ///
    /// The clear is the second thing this path was missing (GitLab #736):
    /// a client keeps showing whatever was last published for a URI, so
    /// closing a file with errors left its entries sitting in the problems
    /// list, attributed to a document the server no longer has.
    private func handleDidClose(params: Any?) {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else { return }
        log("Document closed: \(uri)")
        documentManager.close(uri: uri)
        publishDiagnostics(for: uri, diagnostics: [])
    }

    /// A save may have put an `Action` header on disk, so drop the workspace
    /// action cache and recompile.
    ///
    /// Recompiling *every* open document rather than just the saved one is
    /// the point (GitLab #589): the squiggle that needs clearing is on the
    /// file that *calls* `Application.<Name>`, and that file was compiled
    /// against the stale registry — publishing only this document's
    /// diagnostics would leave the caller marked red until somebody thought
    /// to go and edit it. Open documents are few, and the rescan behind
    /// this is parse-only and cached.
    ///
    /// The live path used to stop after the cache invalidation, which
    /// dropped the stale answer but never asked the question again
    /// (GitLab #736). Only the dead async twin did the recompile.
    private func handleDidSave(params: Any?) {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String else { return }
        log("Document saved: \(uri)")

        workspaceState.invalidateDeclaredActions()

        for (openUri, state) in documentManager.all() {
            let recompiled = documentManager.update(
                uri: openUri, content: state.content, version: state.version
            )
            publishDiagnostics(for: openUri, state: recompiled ?? state)
        }
    }

    private func handleHover(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return hoverHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDefinition(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return definitionHandler.handle(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDocumentHighlight(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }

        let lspPosition = Position(line: line, character: character)
        let lines = LineIndex(state.content)
        let aroPosition = PositionConverter.fromLSP(lspPosition, using: lines)

        guard let result = state.compilationResult else { return nil }

        // Find the symbol name at the cursor position
        var targetName: String?
        var isActionVerb = false

        for analyzed in result.analyzedProgram.featureSets {
            if let found = findHighlightTargetInStatements(
                analyzed.featureSet.statements,
                position: aroPosition,
                isActionVerb: &isActionVerb
            ) {
                targetName = found
                break
            }
        }

        guard let symbolName = targetName else { return nil }

        // Highlight all occurrences of this symbol/verb in the document
        var highlights: [[String: Any]] = []

        for analyzed in result.analyzedProgram.featureSets {
            highlights.append(contentsOf: collectHighlightsInStatements(
                analyzed.featureSet.statements,
                name: symbolName,
                isActionVerb: isActionVerb,
                lines: lines
            ))
        }

        return highlights.isEmpty ? nil : highlights
    }

    /// Find what identifier is at the given position. Returns the name and sets isActionVerb.
    private func findHighlightTargetInStatements(
        _ statements: [Statement],
        position: SourceLocation,
        isActionVerb: inout Bool
    ) -> String? {
        // GitLab #723: highlighting an occurrence inside `when { … }` found
        // nothing, because the chain here descended into loops, match cases
        // and pipelines but not into a `when` block or a match's `otherwise`.
        for aro in AROStatementWalk.flatten(statements) {
            if aro.action.span.contains(position) {
                isActionVerb = true
                return aro.action.verb
            }
            if aro.result.span.contains(position) {
                return aro.result.base
            }
            if aro.object.noun.span.contains(position) {
                return aro.object.noun.base
            }
        }
        return nil
    }

    /// Collect all highlight ranges for the given symbol/verb name.
    private func collectHighlightsInStatements(
        _ statements: [Statement],
        name: String,
        isActionVerb: Bool,
        lines: LineIndex
    ) -> [[String: Any]] {
        var highlights: [[String: Any]] = []

        for aro in AROStatementWalk.flatten(statements) {
            if isActionVerb {
                if aro.action.verb.lowercased() == name.lowercased() {
                    highlights.append(makeHighlight(lines: lines, span: aro.action.span, kind: 1))
                }
            } else {
                if aro.result.base == name {
                    highlights.append(makeHighlight(lines: lines, span: aro.result.span, kind: 2))  // Write
                }
                if aro.object.noun.base == name {
                    highlights.append(makeHighlight(lines: lines, span: aro.object.noun.span, kind: 3))  // Read
                }
            }
        }

        return highlights
    }

    private func makeHighlight(lines: LineIndex, span: SourceSpan, kind: Int) -> [String: Any] {
        let lspRange = PositionConverter.toLSP(span, using: lines)
        return [
            "range": [
                "start": ["line": lspRange.start.line, "character": lspRange.start.character],
                "end": ["line": lspRange.end.line, "character": lspRange.end.character]
            ],
            "kind": kind  // 1=Text, 2=Write, 3=Read
        ]
    }

    private func handleCompletion(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let context = dict["context"] as? [String: Any]
        let triggerCharacter = context?["triggerCharacter"] as? String
        let lspPosition = Position(line: line, character: character)
        return completionHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult, triggerCharacter: triggerCharacter)
    }

    private func handleReferences(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return referencesHandler.handle(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleDocumentSymbol(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.get(uri: uri) else { return nil }
        return documentSymbolHandler.handle(content: state.content, compilationResult: state.compilationResult)
    }

    private func handleWorkspaceSymbol(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let query = dict["query"] as? String else { return nil }
        let allDocuments = documentManager.all()
        return workspaceSymbolHandler.handle(query: query, documents: allDocuments)
    }

    private func handleFormatting(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let options = dict["options"] as? [String: Any],
              let state = documentManager.get(uri: uri) else { return nil }
        let tabSize = options["tabSize"] as? Int ?? 4
        let insertSpaces = options["insertSpaces"] as? Bool ?? true
        return formattingHandler.handle(content: state.content, options: FormattingOptions(tabSize: tabSize, insertSpaces: insertSpaces))
    }

    private func handlePrepareRename(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return renameHandler.prepareRename(uri: uri, position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleRename(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let newName = dict["newName"] as? String,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return renameHandler.handle(uri: uri, position: lspPosition, newName: newName, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleFoldingRange(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.get(uri: uri) else { return nil }
        return foldingRangeHandler.handle(compilationResult: state.compilationResult)
    }

    private func handleSemanticTokens(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let state = documentManager.get(uri: uri) else { return nil }
        return semanticTokensHandler.handle(content: state.content, compilationResult: state.compilationResult)
    }

    private func handleSignatureHelp(params: Any?) -> [String: Any]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let position = dict["position"] as? [String: Any],
              let line = position["line"] as? Int,
              let character = position["character"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        let lspPosition = Position(line: line, character: character)
        return signatureHelpHandler.handle(position: lspPosition, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleCodeAction(params: Any?) -> [[String: Any]]? {
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
              let state = documentManager.get(uri: uri) else { return nil }
        let context = dict["context"] as? [String: Any]
        let diagnostics = context?["diagnostics"] as? [[String: Any]] ?? []
        let startPos = Position(line: startLine, character: startChar)
        let endPos = Position(line: endLine, character: endChar)
        return codeActionHandler.handle(uri: uri, range: (start: startPos, end: endPos), diagnostics: diagnostics, content: state.content, compilationResult: state.compilationResult)
    }

    private func handleInlayHint(params: Any?) -> [[String: Any]]? {
        guard let dict = params as? [String: Any],
              let textDocument = dict["textDocument"] as? [String: Any],
              let uri = textDocument["uri"] as? String,
              let range = dict["range"] as? [String: Any],
              let start = range["start"] as? [String: Any],
              let end = range["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let endLine = end["line"] as? Int,
              let state = documentManager.get(uri: uri) else { return nil }
        return inlayHintHandler.handle(
            compilationResult: state.compilationResult,
            startLine: startLine,
            endLine: endLine,
            bodyLimits: bodyLimits(for: uri)
        )
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

    /// The contract's per-route body limits, for the request-body inlay hint
    /// (GitLab #477). Read from the contract nearest the file being edited,
    /// falling back to the workspace roots.
    private func bodyLimits(for uri: String) -> RouteBodyLimits {
        workspaceState.currentBodyLimits(near: uriToURL(uri))
    }

    // MARK: - Diagnostics Publishing

    private func publishDiagnostics(for uri: String, state: DocumentManager.DocumentState) {
        AROLanguageServer.publishDiagnostics(
            for: uri,
            state: state,
            diagnosticsHandler: diagnosticsHandler
        )
    }

    private func publishDiagnostics(for uri: String, diagnostics: [[String: Any]]) {
        AROLanguageServer.publishDiagnostics(for: uri, diagnostics: diagnostics)
    }

    /// Convert a document's compilation result to LSP diagnostics and
    /// publish them. Declared `static` so the debounced-compile
    /// callback (#352) can publish without capturing `self`, since the
    /// closure is installed on `DocumentManager` during `init` before
    /// `self` is fully formed.
    private static func publishDiagnostics(
        for uri: String,
        state: DocumentManager.DocumentState,
        diagnosticsHandler: DiagnosticsHandler
    ) {
        guard let result = state.compilationResult else {
            publishDiagnostics(for: uri, diagnostics: [])
            return
        }

        let lspDiagnostics = diagnosticsHandler.convert(result.diagnostics, in: state.content)
        publishDiagnostics(for: uri, diagnostics: lspDiagnostics)
    }

    private static func publishDiagnostics(for uri: String, diagnostics: [[String: Any]]) {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "textDocument/publishDiagnostics",
            "params": [
                "uri": uri,
                "diagnostics": diagnostics
            ]
        ]

        if let data = try? JSONSerialization.data(withJSONObject: notification) {
            DiagnosticsSink.shared.send(data)
        }
    }

    /// Where a `publishDiagnostics` notification goes.
    ///
    /// Stdout in production: the client is on the other end of the pipe the
    /// transport reads from, and a notification is framed exactly like a
    /// response. The indirection exists so a test can observe what the
    /// client would have been sent (GitLab #736) — whether a document
    /// notification publishes at all is precisely what diverged between the
    /// two transports, and reading it back off fd 1 would mean redirecting
    /// stdout out from under whatever else the suite is running in
    /// parallel.
    ///
    /// Locked rather than `nonisolated(unsafe)` for the reason every other
    /// shared box in this target is: diagnostics are published from the read
    /// loop *and* from the document manager's debounced-compile task
    /// (#352), which are different threads.
    final class DiagnosticsSink: @unchecked Sendable {
        static let shared = DiagnosticsSink()

        private let lock = NSLock()
        private var captured: [Data]?

        func send(_ data: Data) {
            lock.lock()
            if captured != nil {
                captured?.append(data)
                lock.unlock()
                return
            }
            lock.unlock()

            let header = "Content-Length: \(data.count)\r\n\r\n"
            guard let headerData = header.data(using: .utf8) else { return }
            let output = FileHandle.standardOutput
            output.write(headerData)
            output.write(data)
        }

        /// Run `body` with publishing diverted, and return the notification
        /// payloads it produced instead of writing them to stdout.
        func capturing(_ body: () -> Void) -> [Data] {
            lock.lock(); captured = []; lock.unlock()
            body()
            lock.lock(); defer { captured = nil; lock.unlock() }
            return captured ?? []
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
