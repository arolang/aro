// ============================================================
// LSPEditApplier.swift
// SOLARO — apply LSP TextEdit / WorkspaceEdit lists to disk
// ============================================================
//
// Used by the rename refactor (#256) and the format command
// (#257). Both end up with the same problem: a list of LSP
// TextEdits with 0-based (line, character) positions need to be
// applied to one or more source files. We group by URL, sort
// edits descending per file so later edits don't invalidate the
// offsets of earlier ones, and write back via UTF-8.

import Foundation

enum LSPEditApplier {
    @MainActor
    static func apply(
        edits: [AROLSPClient.TextEdit],
        through controller: WorkspaceController
    ) -> [URL] {
        let grouped = Dictionary(grouping: edits, by: { $0.url })
        var written: [URL] = []
        for (url, fileEdits) in grouped {
            guard var text = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            // Sort by end position descending so each replace doesn't
            // shift the offsets of remaining edits.
            let sorted = fileEdits.sorted { a, b in
                if a.endLine != b.endLine { return a.endLine > b.endLine }
                return a.endChar > b.endChar
            }
            for edit in sorted {
                guard let range = nsRange(in: text, edit: edit) else { continue }
                let ns = text as NSString
                text = ns.replacingCharacters(in: range, with: edit.newText)
            }
            try? text.write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
            controller.lsp.didChange(url: url, text: text)
        }
        // Reparse every touched file so the canvas / outline catches up.
        for url in written {
            controller.openFile(url)
        }
        return written
    }

    /// Convert a 0-based (line, character) range into an NSRange in
    /// the file's text. Falls back to nil if the position is out of
    /// bounds — protects against stale edits arriving after the file
    /// has changed under us.
    private static func nsRange(in text: String, edit: AROLSPClient.TextEdit) -> NSRange? {
        let ns = text as NSString
        var lineStarts: [Int] = [0]
        for i in 0..<ns.length {
            if ns.character(at: i) == 0x0A {
                lineStarts.append(i + 1)
            }
        }
        guard edit.startLine < lineStarts.count,
              edit.endLine < lineStarts.count
        else { return nil }
        let start = lineStarts[edit.startLine] + edit.startChar
        let end = lineStarts[edit.endLine] + edit.endChar
        guard start <= ns.length, end <= ns.length, end >= start else {
            return nil
        }
        return NSRange(location: start, length: end - start)
    }
}
