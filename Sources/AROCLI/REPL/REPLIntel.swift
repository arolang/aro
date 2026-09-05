// ============================================================
// REPLIntel.swift
// ARO REPL — completion + inspection engine (ARO-0091)
// ============================================================
//
// One engine behind the protocol's `complete` / `inspect` and the
// terminal shell's Tab key, so every REPL front-end answers alike.
//
// LSP-backed where AROLSP builds (everywhere but Windows): the
// input is framed exactly the way `execute` frames it — wrapped in
// a temporary feature set unless it already defines one, with the
// session's definitions appended after — compiled, and handed to
// the same `CompletionHandler` / `HoverHandler` that `aro lsp`
// serves. A cell therefore completes the way a document does, by
// construction, including context classification (start of
// statement vs. `<identifier` vs. qualifier slot) and
// compilation-derived symbols.
//
// What the LSP cannot know is merged in from the session: its live
// variables (with their current *values* on inspect), its defined
// feature sets, and the `:` meta-commands. On Windows only this
// session-local layer answers — the pre-LSP behavior, kept as the
// fallback rather than a second code path to maintain: the local
// layer runs everywhere and the LSP layer adds to it.

import Foundation
import AROParser
import ARORuntime
#if !os(Windows)
import AROLSP
#endif

enum REPLIntel {

    struct CompletionAnswer {
        var matches: [String]
        /// Rich items (label / kind / detail) for clients that can
        /// render more than a name list. `matches` is the
        /// authoritative flat list; `items` annotates the candidates
        /// that have metadata (LSP items, session variables).
        var items: [[String: Any]]
        var cursorStart: Int
        var cursorEnd: Int
    }

    // MARK: - Completion

    static func complete(
        code: String,
        cursor: Int,
        session: REPLSession,
        definitions: [String]
    ) -> CompletionAnswer {
        let characters = Array(code)
        let safeCursor = max(0, min(cursor, characters.count))

        // Walk back over the token being typed. `<` and `:` are
        // excluded — they select what kind of name is wanted.
        var start = safeCursor
        while start > 0 {
            let character = characters[start - 1]
            if character.isLetter || character.isNumber || character == "-"
                || character == "_" || character == "." {
                start -= 1
            } else {
                break
            }
        }
        let token = String(characters[start..<safeCursor])
        let preceding = start > 0 ? characters[start - 1] : " "

        var matches: [String] = []
        var items: [[String: Any]] = []

        // --- Session-local layer (all platforms) ---

        if preceding == ":" {
            // A colon opening the line is a meta-command; anywhere
            // else it is `<value: qual` — a qualifier slot. (The old
            // meta branch prefixed candidates with ':' and then
            // filtered them against a token that can never contain
            // one, so it matched nothing.)
            let colonIndex = start - 1
            let colonOpensLine = colonIndex == 0
                || characters[colonIndex - 1] == "\n"
            if colonOpensLine {
                matches += MetaCommandRegistry.shared.commandNames
                    .filter { $0.hasPrefix(token) }
            } else {
                matches += AROCatalog.qualifiersSnapshot()
                    .map(\.fullName)
                    .filter { $0.hasPrefix(token) }
            }
        } else {
            if preceding == "<" {
                matches += session.variableNames.filter { $0.hasPrefix(token) }
            }
            matches += AROCatalog.actionsSnapshot()
                .map(\.verb)
                .filter { $0.lowercased().hasPrefix(token.lowercased()) }
            matches += session.featureSetNames.filter { $0.hasPrefix(token) }
            if preceding != "<" {
                matches += session.variableNames.filter { $0.hasPrefix(token) }
            }
        }

        for name in session.variableNames where name.hasPrefix(token) && !token.isEmpty {
            items.append(["label": name, "kind": 6, "detail": "session variable"])
        }

        // --- LSP layer (adds context-aware answers) ---

        #if !os(Windows)
        let framed = frame(code: code, cursor: safeCursor, definitions: definitions)
        let compiled = Compiler().compile(framed.content)
        let lspItems = CellIntelligence.completions(
            content: framed.content,
            line: framed.line,
            character: framed.character,
            compilationResult: compiled.isSuccess ? compiled : nil
        )
        for item in lspItems {
            // The flat name list replaces [cursorStart, cursorEnd]
            // verbatim, so only word-shaped labels belong in it —
            // snippet items (kind 15) carry placeholder syntax that
            // is only meaningful to a client reading `items`.
            if item.kind != 15 {
                matches.append(item.label)
            }
            var encoded: [String: Any] = ["label": item.label]
            if let kind = item.kind { encoded["kind"] = kind }
            if let detail = item.detail { encoded["detail"] = detail }
            if let insert = item.insertText { encoded["insertText"] = insert }
            items.append(encoded)
        }
        #endif

        // De-dupe, keep deterministic order for the flat name list.
        let uniqueMatches = Array(Set(matches)).sorted()
        var seenLabels: Set<String> = []
        let uniqueItems = items.filter { item in
            guard let label = item["label"] as? String else { return false }
            return seenLabels.insert(label).inserted
        }

        return CompletionAnswer(
            matches: uniqueMatches,
            items: uniqueItems,
            cursorStart: start,
            cursorEnd: safeCursor
        )
    }

    // MARK: - Inspection

    /// "What is this?" for the token under the cursor.
    ///
    /// Priority: a session variable's live *value* (the thing only
    /// the session knows), then the LSP's hover (the thing only a
    /// compilation knows), then the action catalog as the static
    /// fallback.
    static func inspect(
        code: String,
        cursor: Int,
        session: REPLSession,
        definitions: [String]
    ) -> (found: Bool, text: String?) {
        let characters = Array(code)
        let safeCursor = max(0, min(cursor, characters.count))

        var start = safeCursor
        while start > 0, isTokenCharacter(characters[start - 1]) { start -= 1 }
        var end = safeCursor
        while end < characters.count, isTokenCharacter(characters[end]) { end += 1 }

        let token = String(characters[start..<end])
        guard !token.isEmpty else { return (false, nil) }

        if let value = session.getVariable(token) {
            let text = """
            <\(token)>

            \(ResponseFormatter.formatValue(value, for: .human))
            """
            return (true, text)
        }

        #if !os(Windows)
        let framed = frame(code: code, cursor: safeCursor, definitions: definitions)
        let compiled = Compiler().compile(framed.content)
        if let hover = CellIntelligence.hover(
            content: framed.content,
            line: framed.line,
            character: framed.character,
            compilationResult: compiled.isSuccess ? compiled : nil
        ) {
            return (true, hover)
        }
        #endif

        if let action = AROCatalog.actionsSnapshot()
            .first(where: { $0.verb.lowercased() == token.lowercased() }) {
            var text = "\(action.verb) — \(action.role.rawValue) action"
            if !action.prepositions.isEmpty {
                text += "\nPrepositions: \(action.prepositions.joined(separator: ", "))"
            }
            if let description = action.description {
                text += "\n\n\(description)"
            }
            return (true, text)
        }

        return (false, nil)
    }

    // MARK: - Framing

    /// Present the input the way `execute` will run it, and map the
    /// cell-local cursor into that document.
    ///
    /// A cell that already opens a feature set stands as its own
    /// document (wrapping would nest definitions); anything else is
    /// wrapped in the same `(_repl_temp_: Interactive)` frame
    /// execution uses, shifting the cursor down by the one wrapper
    /// line. Definitions are appended after, never prepended, so
    /// the cursor's line stays the line the user is typing on.
    static func frame(
        code: String,
        cursor: Int,
        definitions: [String]
    ) -> (content: String, line: Int, character: Int) {
        // Cursor offset → (line, column) within the cell.
        var line = 0
        var column = 0
        for (offset, character) in code.enumerated() {
            if offset == cursor { break }
            if character == "\n" {
                line += 1
                column = 0
            } else {
                column += 1
            }
        }

        let definesFeatureSet = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("(")

        var content: String
        if definesFeatureSet {
            content = code
        } else {
            content = "(_repl_temp_: Interactive) {\n\(code)\n}"
            line += 1
        }
        if !definitions.isEmpty {
            content += "\n\n" + definitions.joined(separator: "\n\n")
        }
        return (content, line, column)
    }

    static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-"
            || character == "_" || character == "."
    }
}
