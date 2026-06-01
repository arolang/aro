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

    init(url: URL) {
        self.url = url
        self.text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.layout = LayoutSidecar.load(for: url)
        reparse()
    }

    /// Re-run the parser against the current `text` buffer and
    /// refresh `program` / `diagnostics`. Cheap enough to call on
    /// every keystroke for typical `.aro` files; Phase 2+ should
    /// debounce.
    func reparse() {
        let lexer = Lexer(source: text)
        guard let tokens = try? lexer.tokenize() else {
            self.program = nil
            self.diagnostics = []
            return
        }
        let collector = DiagnosticCollector()
        let parser = Parser(tokens: tokens, diagnostics: collector)
        if let parsed = try? parser.parse() {
            self.program = parsed
        } else {
            self.program = nil
        }
        self.diagnostics = collector.diagnostics
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
