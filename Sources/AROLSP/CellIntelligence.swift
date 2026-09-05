// ============================================================
// CellIntelligence.swift
// AROLSP — completion + hover for embedders that don't speak LSP
// ============================================================
//
// The REPL (ARO-0091 `complete` / `inspect`) wants the same answers
// the editors get, without adopting the LSP wire types. This facade
// takes plain line/character integers and returns plain Swift
// values, delegating to the exact handlers `aro lsp` serves — so a
// cell and a document complete identically by construction.

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

public enum CellIntelligence {

    /// One completion candidate. `kind` keeps the LSP numeric
    /// vocabulary (3 = function/action, 6 = variable, 14 = keyword,
    /// 15 = snippet…) so clients that know LSP kinds can map icons,
    /// and everyone else can ignore it.
    public struct CompletionItem: Sendable, Equatable {
        public let label: String
        public let kind: Int?
        public let detail: String?
        public let insertText: String?
    }

    /// Context-aware completions at (line, character) in `content`.
    ///
    /// `compilationResult` supplies document symbols (variables in
    /// scope, feature sets); pass nil for a cell that doesn't compile
    /// yet — the textual-context classification still answers.
    public static func completions(
        content: String,
        line: Int,
        character: Int,
        compilationResult: CompilationResult?
    ) -> [CompletionItem] {
        let reply = CompletionHandler().handle(
            position: Position(line: line, character: character),
            content: content,
            compilationResult: compilationResult,
            triggerCharacter: nil
        )
        let items = reply["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let label = item["label"] as? String, !label.isEmpty else { return nil }
            return CompletionItem(
                label: label,
                kind: item["kind"] as? Int,
                detail: item["detail"] as? String,
                insertText: item["insertText"] as? String
            )
        }
    }

    /// Hover text (markdown) for the token at (line, character), or
    /// nil when the position names nothing the compilation knows.
    public static func hover(
        content: String,
        line: Int,
        character: Int,
        compilationResult: CompilationResult?
    ) -> String? {
        guard let reply = HoverHandler().handle(
            position: Position(line: line, character: character),
            content: content,
            compilationResult: compilationResult
        ) else { return nil }

        if let contents = reply["contents"] as? [String: Any],
           let value = contents["value"] as? String {
            return value
        }
        return reply["contents"] as? String
    }
}
#endif
