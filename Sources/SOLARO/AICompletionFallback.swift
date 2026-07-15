// ============================================================
// AICompletionFallback.swift
// SOLARO — aro ask as a last-resort autocomplete source (#272)
// ============================================================
//
// When `aro lsp` times out or returns no items, we can fall back
// to spawning a one-shot `aro ask` invocation with the
// surrounding source as context. The model returns a short
// prediction of what likely comes next at the caret. Much slower
// than LSP (multi-second), so this is opt-in via the
// `solaro.editor.aiFallback` toggle.

import Foundation

enum AICompletionFallback {
    /// Fire one `aro ask` invocation, capped at `timeout` seconds.
    /// Calls `completion` with the cleaned-up first line of the
    /// model's reply, or nil if anything went wrong / timed out.
    static func predictNext(
        sourceURL: URL,
        project: Project,
        line: Int,
        column: Int,
        timeout: TimeInterval = 20.0,
        completion: @Sendable @escaping (String?) -> Void
    ) {
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8)
        else { completion(nil); return }
        let lines = text.components(separatedBy: "\n")
        guard line < lines.count else { completion(nil); return }

        // Pull 5 lines of context before + the line being edited.
        let lo = max(0, line - 5)
        let hi = min(lines.count - 1, line + 1)
        let context = lines[lo...hi].joined(separator: "\n")
        let target = lines[line]
        let prefix = String(target.prefix(max(0, min(column, target.count))))

        let prompt = """
        You are an inline-suggestion assistant for the ARO language.
        Predict the next few characters that complete the line at the cursor.
        Output ONLY the text to insert, with no quotes, fences, prose, or
        trailing newlines. Keep it under 80 characters.

        Context:
        \(context)

        Line under edit (cursor right after the visible prefix):
        \(prefix)|CURSOR|
        """

        // Record the outbound prompt in the Internal Logs window.
        Task { @MainActor in
            InternalLogStore.shared.record(
                category: .ask, direction: .outbound,
                summary: "→ ask predictNext  ·  \(sourceURL.lastPathComponent):\(line + 1):\(column)",
                body: prompt
            )
        }

        // In-process via the shared, warm AskSession (no subprocess
        // cold start). The service applies its own soft timeout.
        #if canImport(AROAsk)
        Task {
            let raw = await SolaroAskService.shared.complete(prompt, timeout: timeout)
            let source = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let first = source.components(separatedBy: "\n").first ?? ""
            let stripped = first
                .replacingOccurrences(of: "|CURSOR|", with: "")
                .trimmingCharacters(in: .whitespaces)
            let trimmed = String(stripped.prefix(80))
            await MainActor.run {
                InternalLogStore.shared.record(
                    category: .ask,
                    direction: trimmed.isEmpty ? .error : .inbound,
                    summary: trimmed.isEmpty
                        ? "← ask predictNext (no suggestion / unavailable)"
                        : "← ask predictNext result",
                    body: trimmed.isEmpty ? "(empty)" : trimmed
                )
                completion(trimmed.isEmpty ? nil : trimmed)
            }
        }
        #else
        completion(nil)
        #endif
    }
}
