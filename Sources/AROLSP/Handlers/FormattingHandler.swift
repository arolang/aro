// ============================================================
// FormattingHandler.swift
// AROLSP - Code Formatting Provider
// ============================================================

#if !os(Windows)
import Foundation
import AROParser
import LanguageServerProtocol

/// Formatting options from the client
public struct FormattingOptions: Sendable {
    public let tabSize: Int
    public let insertSpaces: Bool

    public init(tabSize: Int, insertSpaces: Bool) {
        self.tabSize = tabSize
        self.insertSpaces = insertSpaces
    }
}

/// Handles textDocument/formatting requests.
///
/// ## Why this is three lines of work and no rules (GitLab #677)
///
/// This handler used to carry its own formatter: a line-by-line state
/// machine that decided indentation from keyword prefixes (`match`, `when`,
/// `for each`, …) and normalised spacing in a `formatStatement` helper. The
/// helper was reached only from
///
/// ```swift
/// if inFeatureSet && trimmed.hasPrefix("<") { … }
/// ```
///
/// and statements stopped beginning with `<` when bracketed verbs were
/// removed (GitLab #514 / #574). So every statement fell through to "keep the
/// text, change the indent" and `formatStatement` was dead code — the
/// formatter never formatted a statement.
///
/// Reviving that branch would have left two formatters in the repo that
/// disagree: SOLARO's `AROFormatter` indents from bracket depth, collapses
/// blank runs, fixes trailing double dots and guarantees a final newline,
/// none of which the LSP copy did. A file formatted in the editor and the
/// same file formatted through an LSP client would have come out different,
/// which is a worse bug than the dead branch.
///
/// So there is one formatter now. `AROFormatter` moved into AROParser — the
/// lowest module both surfaces already depend on — gained the interior-space
/// collapsing that `formatStatement` was meant to do, and this handler is
/// reduced to translating LSP's options in and LSP's edit shape out.
public struct FormattingHandler: Sendable {

    public init() {}

    /// Handle a formatting request
    public func handle(
        content: String,
        options: FormattingOptions
    ) -> [[String: Any]]? {
        guard !content.isEmpty else { return nil }

        let formatted = AROFormatter.format(
            content,
            indentWidth: options.tabSize,
            useTabs: !options.insertSpaces
        )

        // Nothing to do — tell the client so rather than making it apply a
        // no-op edit that would still dirty the buffer and move the cursor.
        if formatted == content { return nil }

        // One edit replacing the whole document. The end position is one line
        // past the last, character 0, which is how LSP spells "to the end"
        // for a document whose final line may or may not carry a newline.
        let lineCount = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return [[
            "range": [
                "start": ["line": 0, "character": 0],
                "end": ["line": lineCount, "character": 0]
            ],
            "newText": formatted
        ]]
    }
}

#endif
