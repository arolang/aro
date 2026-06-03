// ============================================================
// CompletionHandler.swift
// AROLSP - Completion Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import ARORuntime
import LanguageServerProtocol

/// Handles textDocument/completion requests
public struct CompletionHandler: Sendable {

    public init() {}

    /// Handle a completion request.
    ///
    /// Strategy: look at the prefix of the current line up to the cursor,
    /// classify what the user is *probably* typing right now, and only
    /// return suggestions valid in that position. Prefix-filtered server
    /// side so the client doesn't have to discard hundreds of items.
    public func handle(
        position: Position,
        content: String,
        compilationResult: CompilationResult?,
        triggerCharacter: String?
    ) -> [String: Any] {
        let context = Self.parseContext(
            content: content,
            line: position.line,
            character: position.character
        )

        var items: [[String: Any]] = []

        // The explicit trigger character takes priority — typing `<` is
        // always an identifier opener, `:` is always a qualifier slot,
        // `.` is always member access. Otherwise fall back to the
        // textual-context classifier.
        switch triggerCharacter {
        case "<":
            items.append(contentsOf: variableCompletions(
                compilationResult: compilationResult,
                prefix: "",
                appendBracket: true
            ))
            items.append(contentsOf: actionCompletions(
                prefix: "", appendBracket: true
            ))
        case ":":
            items.append(contentsOf: qualifierCompletions(prefix: ""))
        case ".":
            items.append(contentsOf: memberCompletions())
        default:
            switch context.kind {
            case .startOfStatement:
                items.append(contentsOf: actionCompletions(
                    prefix: context.prefix, appendBracket: false
                ))
                items.append(contentsOf: keywordCompletions(
                    prefix: context.prefix, scope: .statementOpener
                ))
                if context.prefix.isEmpty {
                    items.append(contentsOf: snippetCompletions())
                }
            case .afterAction, .afterArticle, .afterPreposition:
                // The user just finished a verb / preposition + space and
                // is about to introduce an `<identifier>`. Suggest the
                // article words and a `<` snippet — no verbs, no
                // variables out of context.
                items.append(contentsOf: keywordCompletions(
                    prefix: context.prefix, scope: .afterVerbOrPrep
                ))
                items.append(contentsOf: openBracketSnippet())
            case .insideIdentifier:
                items.append(contentsOf: variableCompletions(
                    compilationResult: compilationResult,
                    prefix: context.prefix,
                    appendBracket: true
                ))
            case .afterColon:
                items.append(contentsOf: qualifierCompletions(
                    prefix: context.prefix
                ))
            case .inFeatureSetHeader:
                // Inside `(Name: Activity)` — no action verbs, just hint
                // the snippet keywords that legitimately appear there.
                items.append(contentsOf: keywordCompletions(
                    prefix: context.prefix, scope: .featureSetHeader
                ))
            }
        }

        // De-dupe by `(kind, label)` so AROCatalog's duplicate verbs
        // (the catalog can list "Map" twice if a plugin re-registers it)
        // collapse into one item per name.
        var seen: Set<String> = []
        let deduped = items.filter { item in
            let key = "\(item["kind"] ?? "?"):\(item["label"] ?? "?")"
            return seen.insert(key).inserted
        }

        // Hard cap so even a flood of variables doesn't overwhelm the UI.
        // `isIncomplete = true` tells the client we'd return more if the
        // user kept typing.
        let cap = 30
        let capped = Array(deduped.prefix(cap))
        return [
            "isIncomplete": deduped.count > cap,
            "items": capped
        ]
    }

    // MARK: - Context detection

    /// What kind of token the user is probably typing at the cursor.
    private enum ContextKind {
        case startOfStatement     // empty line / partial action verb
        case afterAction          // `Log ` or `Compute ` — expecting article + `<`
        case afterArticle         // `the ` — expecting `<`
        case afterPreposition     // `from `, `to `, `with `… — expecting article / `<`
        case insideIdentifier     // typing inside `<…` not yet closed
        case afterColon           // inside `<name: …` — expecting qualifier
        case inFeatureSetHeader   // typing inside `(Name: …)`
    }

    private struct CompletionContext {
        let kind: ContextKind
        /// Partial word the user has typed at the cursor (case preserved).
        /// Used for prefix-filtering candidates server-side.
        let prefix: String
    }

    private static let prepositions: Set<String> = [
        "from", "to", "with", "into", "against", "for", "by", "at", "on", "via",
    ]
    private static let articles: Set<String> = ["the", "a", "an"]

    private static func parseContext(
        content: String,
        line: Int,
        character: Int
    ) -> CompletionContext {
        let lines = content.components(separatedBy: "\n")
        guard line < lines.count else {
            return .init(kind: .startOfStatement, prefix: "")
        }
        let lineText = lines[line]
        let safeChar = min(max(0, character), lineText.count)
        let upToCursor = String(
            lineText.prefix(safeChar)
        )

        // Are we inside an unclosed `<…>` on this line?
        var openCount = 0
        var closeCount = 0
        for ch in upToCursor {
            if ch == "<" { openCount += 1 }
            if ch == ">" { closeCount += 1 }
        }
        let insideBracket = openCount > closeCount

        if insideBracket, let lastOpen = upToCursor.lastIndex(of: "<") {
            let inner = upToCursor[upToCursor.index(after: lastOpen)...]
            if let colonIdx = inner.firstIndex(of: ":") {
                let afterColon = inner[inner.index(after: colonIdx)...]
                let prefix = String(afterColon)
                    .trimmingCharacters(in: .whitespaces)
                return .init(kind: .afterColon, prefix: prefix)
            }
            return .init(kind: .insideIdentifier, prefix: String(inner))
        }

        // Feature-set header: cursor sits inside `(...)` that hasn't closed.
        var parenDepth = 0
        for ch in upToCursor {
            if ch == "(" { parenDepth += 1 }
            if ch == ")" { parenDepth -= 1 }
        }
        if parenDepth > 0 {
            let lastWord = upToCursor
                .split(whereSeparator: { $0.isWhitespace || $0 == "(" })
                .last
                .map(String.init) ?? ""
            return .init(
                kind: .inFeatureSetHeader,
                prefix: upToCursor.hasSuffix(" ") ? "" : lastWord
            )
        }

        // Outside brackets: classify by the last completed word + whether
        // we're mid-word or just past a space.
        let trimmed = upToCursor.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .init(kind: .startOfStatement, prefix: "")
        }

        // Words on this line so far, in order.
        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let lastWord = words.last ?? ""
        let mid = !upToCursor.hasSuffix(" ")

        if mid {
            // We're still typing `lastWord`. Always treat as
            // start-of-statement so the action-verb catalogue + keywords
            // get prefix-filtered.
            return .init(kind: .startOfStatement, prefix: lastWord)
        }

        // Cursor sits right after a space.
        let lower = lastWord.lowercased()
        if prepositions.contains(lower) {
            return .init(kind: .afterPreposition, prefix: "")
        }
        if articles.contains(lower) {
            return .init(kind: .afterArticle, prefix: "")
        }
        // Heuristic: a verb-shape word (Capitalised) followed by space.
        if let first = lastWord.first, first.isUppercase, words.count == 1 {
            return .init(kind: .afterAction, prefix: "")
        }
        // Default: still in statement, ready for next word.
        return .init(kind: .startOfStatement, prefix: "")
    }

    /// Single-item completion that opens an identifier bracket. Surfaced
    /// in the after-verb / after-preposition contexts so the user has a
    /// one-keystroke path to `<…>`.
    private func openBracketSnippet() -> [[String: Any]] {
        return [[
            "label": "<…>",
            "kind": 15,  // Snippet
            "detail": "Open an identifier reference",
            "insertText": "<${1:name}>",
            "insertTextFormat": 2,
        ]]
    }

    // MARK: - Action Completions

    /// Build action completion items from the AROCatalog snapshot.
    ///
    /// `appendBracket` controls whether the inserted text gets a trailing
    /// `>`. Inside `<…>` the `>` is what closes the identifier reference;
    /// outside, appending one produces broken syntax like `Log >`, which
    /// is exactly what the prior implementation did.
    private func actionCompletions(
        prefix: String,
        appendBracket: Bool
    ) -> [[String: Any]] {
        let needle = prefix.lowercased()
        let entries = AROCatalog.actionsSnapshot()
        return entries
            .filter { entry in
                needle.isEmpty
                    || entry.verb.lowercased().hasPrefix(needle)
            }
            .map { entry in
                let detail = "[\(entry.role.rawValue.uppercased())] \(entry.description ?? "")"
                let insert = appendBracket ? "\(entry.verb)>" : entry.verb
                var item: [String: Any] = [
                    "label": entry.verb,
                    "kind": 3,  // Function
                    "detail": detail,
                    "insertText": insert,
                    "insertTextFormat": 1,
                ]
                if case .plugin(let name, _) = entry.origin {
                    item["documentation"] = [
                        "kind": "markdown",
                        "value": "From plugin **\(name)**.\n\n\(entry.description ?? "")",
                    ]
                }
                return item
            }
    }

    // MARK: - Variable Completions

    private func variableCompletions(
        compilationResult: CompilationResult?,
        prefix: String,
        appendBracket: Bool
    ) -> [[String: Any]] {
        guard let result = compilationResult else { return [] }
        let needle = prefix.lowercased()
        var items: [[String: Any]] = []
        for analyzed in result.analyzedProgram.featureSets {
            for (name, symbol) in analyzed.symbolTable.symbols {
                if !needle.isEmpty,
                   !name.lowercased().hasPrefix(needle)
                {
                    continue
                }
                let typeStr = symbol.dataType?.description ?? "Unknown"
                let insert = appendBracket ? "\(name)>" : name
                items.append([
                    "label": name,
                    "kind": 6,  // Variable
                    "detail": typeStr,
                    "documentation": "Source: \(symbol.source)",
                    "insertText": insert,
                    "insertTextFormat": 1,
                ])
            }
        }
        return items
    }

    // MARK: - Qualifier Completions

    /// Build qualifier completion items from the AROCatalog snapshot.
    /// Built-in qualifiers appear bare (`uppercase`); plugin qualifiers appear
    /// twice — once bare (`reverse`) and once namespaced (`collections.reverse`).
    /// `prefix` filters by case-insensitive `hasPrefix`. Caller is
    /// responsible for the surrounding context (we're always inside
    /// `<name: …>`), so the inserted text is the qualifier name alone —
    /// no leading space, no trailing `>`. The user closes the bracket
    /// themselves, which means the suggestion stops being position-
    /// sensitive about typing-state.
    private func qualifierCompletions(prefix: String) -> [[String: Any]] {
        let needle = prefix.lowercased()
        var items: [[String: Any]] = []

        for entry in AROCatalog.qualifiersSnapshot() {
            let originLabel: String = {
                if case .plugin(let name, _) = entry.origin { return " (plugin: \(name))" }
                return ""
            }()
            let detail = (entry.description ?? "qualifier") + originLabel

            if needle.isEmpty
                || entry.qualifier.lowercased().hasPrefix(needle)
            {
                items.append([
                    "label": entry.qualifier,
                    "kind": 10,
                    "detail": detail,
                    "insertText": entry.qualifier,
                    "insertTextFormat": 1,
                ])
            }

            if !entry.namespace.isEmpty,
               needle.isEmpty
                || entry.fullName.lowercased().hasPrefix(needle)
            {
                items.append([
                    "label": entry.fullName,
                    "kind": 10,
                    "detail": detail,
                    "insertText": entry.fullName,
                    "insertTextFormat": 1,
                ])
            }
        }

        // List element specifiers (ARO-0038) — these aren't true qualifiers
        // in the registry but show up after `:` in completion contexts.
        let specifiers: [(String, String)] = [
            ("0", "Last element (reverse index)"),
            ("1", "Second-to-last element"),
            ("2", "Third-to-last element"),
        ]
        for (label, detail) in specifiers {
            if needle.isEmpty || label.hasPrefix(needle) {
                items.append([
                    "label": label,
                    "kind": 10,
                    "detail": detail,
                    "insertText": label,
                    "insertTextFormat": 1,
                ])
            }
        }

        return items
    }

    // MARK: - Member Completions

    private func memberCompletions() -> [[String: Any]] {
        // Default members for unknown types
        return typeAwareMemberCompletions(for: nil)
    }

    /// Type-aware member completions based on the variable's data type
    private func typeAwareMemberCompletions(for dataType: DataType?) -> [[String: Any]] {
        var members: [(String, String)] = []

        guard let type = dataType else {
            // Generic members for unknown types
            members = [
                ("length", "Array/string length"),
                ("count", "Element count"),
                ("first", "First element"),
                ("last", "Last element"),
                ("keys", "Map keys"),
                ("values", "Map values"),
                ("isEmpty", "True if empty"),
            ]
            return members.map { member in
                [
                    "label": member.0,
                    "kind": 10,  // Property
                    "detail": member.1,
                    "insertText": member.0,
                    "insertTextFormat": 1
                ]
            }
        }

        switch type {
        case .list:
            members = [
                ("length", "Number of elements in list"),
                ("count", "Number of elements in list"),
                ("first", "First element of list"),
                ("last", "Last element of list"),
                ("isEmpty", "True if list is empty"),
            ]
        case .map:
            members = [
                ("keys", "All keys in the map"),
                ("values", "All values in the map"),
                ("count", "Number of key-value pairs"),
                ("isEmpty", "True if map is empty"),
            ]
        case .string:
            members = [
                ("length", "Number of characters"),
                ("isEmpty", "True if string is empty"),
                ("uppercase", "Uppercase version"),
                ("lowercase", "Lowercase version"),
                ("trimmed", "Whitespace trimmed version"),
            ]
        case .integer, .float:
            members = [
                ("abs", "Absolute value"),
                ("string", "String representation"),
            ]
        case .boolean:
            members = [
                ("not", "Negated value"),
                ("string", "String representation"),
            ]
        case .schema, .unknown:
            // Generic members for unknown/schema types
            members = [
                ("length", "Array/string length"),
                ("count", "Element count"),
                ("first", "First element"),
                ("last", "Last element"),
                ("keys", "Map keys"),
                ("values", "Map values"),
                ("isEmpty", "True if empty"),
            ]
        }

        return members.map { member in
            [
                "label": member.0,
                "kind": 10,  // Property
                "detail": member.1,
                "insertText": member.0,
                "insertTextFormat": 1
            ]
        }
    }

    /// Get type-aware completions for a specific position
    public func handleWithTypeContext(
        position: Position,
        content: String,
        compilationResult: CompilationResult?,
        triggerCharacter: String?
    ) -> [String: Any] {
        var items: [[String: Any]] = []

        // For "." trigger, try to find the type of the variable before the dot
        if triggerCharacter == "." {
            if let dataType = findTypeAtPosition(position: position, content: content, compilationResult: compilationResult) {
                items.append(contentsOf: typeAwareMemberCompletions(for: dataType))
            } else {
                items.append(contentsOf: memberCompletions())
            }
        } else {
            // Delegate to regular handle for other cases
            return handle(position: position, content: content, compilationResult: compilationResult, triggerCharacter: triggerCharacter)
        }

        return [
            "isIncomplete": false,
            "items": items
        ]
    }

    /// Find the data type of the variable at the given position
    private func findTypeAtPosition(
        position: Position,
        content: String,
        compilationResult: CompilationResult?
    ) -> DataType? {
        guard let result = compilationResult else { return nil }

        // Get the line content up to the cursor
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard position.line < lines.count else { return nil }

        let line = String(lines[position.line])
        let prefixEnd = line.index(line.startIndex, offsetBy: min(position.character, line.count))
        let prefix = String(line[..<prefixEnd])

        // Look for variable name before the dot
        // Pattern: <variable-name>.
        let pattern = "<([a-zA-Z][a-zA-Z0-9-]*)>\\s*\\.$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let varRange = Range(match.range(at: 1), in: prefix) else {
            return nil
        }

        let variableName = String(prefix[varRange])

        // Look up the variable in symbol tables
        for analyzed in result.analyzedProgram.featureSets {
            if let symbol = analyzed.symbolTable.lookup(variableName) {
                return symbol.dataType
            }
        }

        return nil
    }

    // MARK: - Keyword Completions

    enum KeywordScope {
        case statementOpener   // beginning of a statement / partial verb
        case afterVerbOrPrep   // just past `Log ` / `from ` — articles only
        case featureSetHeader  // inside `(Name: Activity)`
    }

    private func keywordCompletions(
        prefix: String,
        scope: KeywordScope
    ) -> [[String: Any]] {
        let needle = prefix.lowercased()

        // Statement openers: control-flow + the "default" keyword used in
        // optional retrieve clauses. Prepositions and articles aren't
        // here — those are only valid *after* a verb so they live in the
        // afterVerbOrPrep bucket.
        let opener: [(String, String)] = [
            ("match", "Pattern matching"),
            ("when", "Condition branch"),
            ("for each", "Iterate over a collection"),
            ("for", "Range loop (for <var> from N to M)"),
            ("while", "Conditional loop"),
            ("break", "Exit current loop"),
            ("if", "Conditional"),
            ("else", "Alternative branch"),
        ]

        // After a verb / preposition the next legal tokens are an article
        // or a `<identifier>` — no other verb, no other preposition.
        let afterVerbOrPrep: [(String, String)] = [
            ("the", "Article"),
            ("a", "Article"),
            ("an", "Article"),
        ]

        let pool: [(String, String)]
        switch scope {
        case .statementOpener: pool = opener
        case .afterVerbOrPrep: pool = afterVerbOrPrep
        case .featureSetHeader: pool = []
        }

        return pool
            .filter { needle.isEmpty || $0.0.lowercased().hasPrefix(needle) }
            .map { keyword in
                [
                    "label": keyword.0,
                    "kind": 14,  // Keyword
                    "detail": keyword.1,
                    "insertText": keyword.0,
                    "insertTextFormat": 1,
                ]
            }
    }

    // MARK: - Snippet Completions

    private func snippetCompletions() -> [[String: Any]] {
        return [
            [
                "label": "feature set",
                "kind": 15,  // Snippet
                "detail": "Create a new feature set",
                "insertText": "(${1:feature-name}: ${2:Business Activity}) {\n\t$0\n}",
                "insertTextFormat": 2  // Snippet
            ],
            [
                "label": "aro statement",
                "kind": 15,
                "detail": "Create an ARO statement",
                "insertText": "<${1:Action}> the <${2:result}> ${3|from,to,with,for|} the <${4:object}>.",
                "insertTextFormat": 2
            ],
            [
                "label": "app start",
                "kind": 15,
                "detail": "Application start handler",
                "insertText": "(Application-Start: ${1:App Name}) {\n\tLog \"Starting...\" to the <console>.\n\t$0\n\tReturn an <OK: status> for the <startup>.\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "http handler",
                "kind": 15,
                "detail": "HTTP operation handler",
                "insertText": "(${1:operationId}: ${2:API}) {\n\tExtract the <data> from the <request: body>.\n\t$0\n\tReturn an <OK: status> with <result>.\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "for each loop",
                "kind": 15,
                "detail": "Iterate over a collection",
                "insertText": "for each <${1:item}> in <${2:collection}> {\n\t$0\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "for range loop",
                "kind": 15,
                "detail": "Iterate over a numeric range",
                "insertText": "for <${1:i}> from ${2:0} to <${3:count}> {\n\t$0\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "while loop",
                "kind": 15,
                "detail": "Loop while condition holds",
                "insertText": "while <${1:condition}> {\n\t$0\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "match statement",
                "kind": 15,
                "detail": "Pattern match on a value",
                "insertText": "match <${1:value}> {\n\tcase ${2:pattern} {\n\t\t$0\n\t}\n}",
                "insertTextFormat": 2
            ],
            [
                "label": "event handler",
                "kind": 15,
                "detail": "Custom event handler",
                "insertText": "(${1:Name}: ${2:EventName} Handler) {\n\tExtract the <${3:data}> from the <event: ${3:data}>.\n\t$0\n}",
                "insertTextFormat": 2
            ],
        ]
    }
}

#endif
