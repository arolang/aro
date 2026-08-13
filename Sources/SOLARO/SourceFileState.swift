// ============================================================
// SourceFileState.swift
// SOLARO — per-open-file state model
// ============================================================
//
// One instance per `.aro` file the user is actively viewing. Holds
// the on-disk path, the editable text buffer, the last-known
// layout sidecar, and the parsed AST (when available). Phase 1
// uses this to drive the editor + inspector; Phase 2 will add
// canvas node state.

import Foundation
import AROParser

/// State for one open source file.
final class SourceFileState: Identifiable, Equatable {

    let url: URL
    var id: String { url.path }

    /// Mutable text buffer the editor binds to. Reset to the
    /// on-disk contents at load and at "discard" time.
    var text: String

    /// Last layout sidecar read from disk. Mutated as the user
    /// switches pane modes; written back atomically on change.
    var layout: LayoutSidecar

    /// Last parsed AST, if parsing succeeded. Nil before the first
    /// parse or after a fatal error.
    private(set) var program: Program?

    /// Diagnostics from the last parse — empty when clean.
    private(set) var diagnostics: [Diagnostic] = []

    /// True once `load()` has run. Distinguishes "empty file" from
    /// "not read yet" for callers that show a placeholder.
    private(set) var isLoaded: Bool = false

    /// Cheap, non-blocking. The file is *not* read here (#487):
    /// reading and parsing in an initializer meant both landed on
    /// whichever thread constructed the state — in practice the
    /// main one — so opening a large file froze the UI before any
    /// of the async plumbing downstream got a say. Call `load()`.
    init(url: URL) {
        self.url = url
        self.text = ""
        self.layout = LayoutSidecar.load(for: url)
    }

    /// Read the file off the main thread and parse it — unless it is
    /// large enough that parsing would block, in which case the text
    /// loads and `program` stays nil.
    func load() async {
        let url = self.url
        let text = await Task.detached(priority: .userInitiated) {
            StreamReader(url: url).readAll()
        }.value
        self.text = text
        self.isLoaded = true
        guard LargeFilePolicy.shouldParse(url) else {
            program = nil
            diagnostics = []
            return
        }
        await reparseOffMainThread()
    }

    /// Parse on a background task and publish the result. Used by
    /// `load()`; callers that edit the buffer can use it too rather
    /// than paying for `reparse()` inline on every keystroke.
    func reparseOffMainThread() async {
        let source = text
        let parsed = await Task.detached(priority: .utility) {
            SourceFileState.parse(source)
        }.value
        self.program = parsed.program
        self.diagnostics = parsed.diagnostics
    }

    /// Re-run the parser against the current `text` buffer and
    /// refresh `program` / `diagnostics`. Synchronous — fine for
    /// typical `.aro` files, but see `reparseOffMainThread()`.
    func reparse() {
        let parsed = Self.parse(text)
        self.program = parsed.program
        self.diagnostics = parsed.diagnostics
    }

    /// Pure lex + parse. Static and free of `self` so it can run on
    /// a detached task without dragging the state object across the
    /// concurrency boundary.
    private static func parse(
        _ source: String
    ) -> (program: Program?, diagnostics: [Diagnostic]) {
        let lexer = Lexer(source: source)
        guard let tokens = try? lexer.tokenize() else {
            return (nil, [])
        }
        let collector = DiagnosticCollector()
        let parser = Parser(tokens: tokens, diagnostics: collector)
        let program = try? parser.parse()
        return (program, collector.diagnostics)
    }

    /// Save back to disk + refresh the on-disk mirror. Errors
    /// propagate so the toolbar can surface them.
    func saveToDisk() throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func == (lhs: SourceFileState, rhs: SourceFileState) -> Bool {
        lhs.url == rhs.url
    }
}
