// ============================================================
// WorkspaceLSPActions.swift
// SOLARO — the workspace's language-server calls (#772)
// ============================================================
//
// `Workspace.swift` was a view, a command router, an LSP client and a
// git driver in one 2200-line file, and the compiler had started to
// notice: two handlers were already extracted because "the Swift
// type-checker started timing out trying to infer it in-place".
//
// This is the language-server half — go to definition, hover, find
// references, completion, rename with its preview, and format — moved
// out whole as an extension on `WorkspaceView`. It is an extension
// rather than a new type because these methods read the view's
// `@State` (the hover sheet, the completion list, the rename preview)
// and drive it; turning that into a separate object would mean
// inventing a binding for each, which is more machinery than the split
// is worth.
//
// `CaretContext` comes with them. It is the reason these belong
// together: every one of them resolves a position against the *live
// editor buffer* rather than the file on disk, and that shared
// discipline is easier to keep in one file than scattered through a
// view body.

import SwiftUI
import AppKit
import AROParser

extension WorkspaceView {

    /// Everything a caret-based LSP request needs, resolved against
    /// the LIVE editor buffer rather than the file on disk
    /// (GitLab #535). The two diverge whenever a write failed or is
    /// still in flight, and a position computed against disk then
    /// resolves to the wrong column — or the wrong line entirely.
    /// Also nudges the server's document mirror into step first, so
    /// the position we send means what we think it means.
    struct CaretContext {
        let url: URL
        let text: String
        /// 0-based line, as LSP wants it.
        let line0: Int
        let column: Int
        let line: String
    }

    func caretContext() -> CaretContext? {
        guard
            let url = controller.currentFile,
            let lineNumber = controller.currentLine,
            let text = controller.liveText(for: url)
        else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard lineNumber - 1 < lines.count else { return nil }
        controller.syncLSPWithLiveText(url)
        let line = lines[lineNumber - 1]
        return CaretContext(url: url, text: text,
                            line0: lineNumber - 1,
                            column: resolvedColumn(for: line),
                            line: line)
    }

    /// Every place the symbol under the caret is used (#764).
    ///
    /// "Where is this event handled?" is the question an event-driven
    /// language is built around, and it was the one navigation the IDE
    /// could not answer — the server has advertised `referencesProvider`
    /// the whole time and nothing asked it. Results land in the same
    /// panel as a project search, which already knows how to open one.
    func findReferences() {
        guard let caret = caretContext() else { return }
        let symbol = symbolUnderCaret(in: caret) ?? ""
        let root = project.rootPath
        controller.lsp.references(
            url: caret.url, line0: caret.line0, character0: caret.column
        ) { locations in
            guard !locations.isEmpty else {
                controller.globalSearchHits = []
                controller.globalSearchPanelVisible = true
                return
            }
            let hits = locations.map { location in
                GlobalSearchHit.reference(
                    at: location,
                    symbol: symbol,
                    snippet: sourceLine(location.line, of: location.url),
                    projectRoot: root
                )
            }
            controller.globalSearchHits = hits
            controller.globalSearchSelectedIndex = 0
            controller.globalSearchPanelVisible = true
        }
    }

    /// The identifier the caret sits in, for labelling reference rows.
    func symbolUnderCaret(in caret: CaretContext) -> String? {
        let characters = Array(caret.line)
        guard caret.column < characters.count else { return nil }
        let isPart: (Character) -> Bool = {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
        guard isPart(characters[caret.column]) else { return nil }
        var start = caret.column
        while start > 0, isPart(characters[start - 1]) { start -= 1 }
        var end = caret.column
        while end + 1 < characters.count, isPart(characters[end + 1]) { end += 1 }
        return String(characters[start...end])
    }

    /// One source line, from the buffer so an unsaved edit reads right.
    func sourceLine(_ line: Int, of url: URL) -> String? {
        guard let text = controller.liveText(for: url) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        return lines[line - 1]
    }

    func goToDefinition() {
        guard let caret = caretContext() else { return }
        controller.lsp.definition(
            url: caret.url,
            line0: caret.line0,
            character0: caret.column
        ) { location in
            guard let location else { return }
            controller.openFile(location.url)
            controller.currentLine = location.line
        }
    }

    /// Pop the Hover sheet for the current caret position. Same
    /// column heuristic as goToDefinition: use the editor-reported
    /// column when we have one, otherwise the first `<` or first
    /// non-whitespace character on the line.
    func hoverAtCaret() {
        guard let caret = caretContext() else { return }
        hoverState.content = ""
        hoverState.hasResult = false
        hoverState.isLoading = true
        hoverState.symbol = identifierAround(line: caret.line,
                                             column: caret.column)
        showHoverSheet = true
        controller.lsp.hover(
            url: caret.url,
            line0: caret.line0,
            character0: caret.column
        ) { content in
            hoverState.isLoading = false
            hoverState.hasResult = true
            hoverState.content = content ?? ""
        }
    }

    /// Best-effort: pluck the identifier surrounding the column for
    /// the sheet's title bar. Doesn't influence the actual LSP
    /// request — that uses the column directly.
    func identifierAround(line: String, column: Int) -> String? {
        guard column >= 0, column <= line.count else { return nil }
        let chars = Array(line)
        let i = min(column, chars.count - 1)
        let isIdent: (Character) -> Bool = { c in
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }
        guard i >= 0, i < chars.count, isIdent(chars[i]) else { return nil }
        var start = i
        while start > 0, isIdent(chars[start - 1]) { start -= 1 }
        var end = i
        while end < chars.count - 1, isIdent(chars[end + 1]) { end += 1 }
        return String(chars[start...end])
    }

    // MARK: - LSP autocompletion (#254)

    func triggerCompletion() {
        guard let caret = caretContext() else { return }

        completionState.items = []
        completionState.isLoading = true
        completionState.hasResult = false
        completionState.selection = nil
        showCompletionSheet = true

        controller.lsp.completion(
            url: caret.url, line0: caret.line0, character0: caret.column
        ) { items in
            completionState.items = items
            completionState.isLoading = false
            completionState.hasResult = true
            completionState.selection = items.first?.id
        }
    }

    func acceptCompletion(_ item: AROLSPClient.CompletionItem) {
        showCompletionSheet = false
        guard let caret = caretContext() else { return }
        // Insert the chosen text at the current caret position,
        // computed against the live buffer (GitLab #535).
        let ns = caret.text as NSString
        var lineStarts: [Int] = [0]
        for i in 0..<ns.length {
            if ns.character(at: i) == 0x0A { lineStarts.append(i + 1) }
        }
        let insertOffset = lineStarts[caret.line0] + caret.column
        guard insertOffset <= ns.length else { return }
        let insertRange = NSRange(location: insertOffset, length: 0)
        let insertLength = (item.insertText as NSString).length

        // Edit the OPEN buffer through the undoable replace path.
        // This used to splice a disk snapshot, write the file and call
        // `openFile` — a whole-document swap that hits
        // `updateNSView`'s external-swap branch, whose
        // `removeAllActions()` erased the file's entire undo history
        // every time the user accepted one suggestion.
        if controller.replaceInOpenBuffer(
            url: caret.url,
            range: insertRange,
            with: item.insertText,
            actionName: "Accept Completion",
            caretOffset: insertOffset + insertLength
        ) {
            // The editor propagates the new text back through the
            // editable binding on the next runloop tick, which writes
            // disk, syncs the LSP and reparses.
            return
        }

        // No open editor for this file (canvas-only pane): fall back
        // to the disk path.
        let text = ns.replacingCharacters(in: insertRange,
                                          with: item.insertText)
        controller.writeToDisk(text, to: caret.url)
        controller.liveEditorText[caret.url.standardizedFileURL] = text
        controller.lsp.didChange(url: caret.url, text: text)
        controller.openFile(caret.url)
    }

    // MARK: - LSP rename (#256)

    func beginRename() {
        renameNewName = ""
        renameError = nil
        renamePreview = nil
        renameEdits = []
        showRenameSheet = true
    }

    /// Ask the server what the rename would do, and show it (#764).
    ///
    /// The edits are kept, so confirming applies exactly what was on
    /// screen. Asking again at confirm time would risk applying
    /// something the user never saw — the buffer can change between
    /// the two requests.
    func previewRename() {
        guard let caret = caretContext() else { return }
        let newName = renameNewName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else {
            renameError = "Enter a new name."
            return
        }
        renameError = nil
        // The edits carry positions into the server's copy of the
        // document, so make that the live buffer first (GitLab #535).
        controller.syncLSPWithLiveText(caret.url)
        controller.lsp.rename(
            url: caret.url, line0: caret.line0, character0: caret.column,
            newName: newName
        ) { edits, error in
            guard let edits else {
                renameError = error ?? "Rename failed."
                return
            }
            renameEdits = edits
            renamePreview = RenamePreview(edits: edits)
        }
    }

    func applyRename() {
        guard !renameEdits.isEmpty else {
            renameError = "Nothing to rename."
            return
        }
        _ = LSPEditApplier.apply(edits: renameEdits, through: controller)
        showRenameSheet = false
    }

    // MARK: - LSP formatting (#257)

    func formatDocument() {
        guard let url = controller.currentFile else { return }
        // The returned edits carry positions into the server's copy
        // of the document — make sure that's the live buffer before
        // asking (GitLab #535).
        controller.syncLSPWithLiveText(url)
        controller.lsp.format(url: url) { edits in
            guard !edits.isEmpty else { return }
            _ = LSPEditApplier.apply(edits: edits, through: controller)
        }
    }
}
