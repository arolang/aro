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

        let aro = ConsoleProcess.resolveAroBinary(near: project)
        let task = Process()
        if aro == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["aro", "ask", "--yes", "--no-think", prompt]
        } else {
            task.executableURL = URL(fileURLWithPath: aro)
            task.arguments = ["ask", "--yes", "--no-think", prompt]
        }
        task.currentDirectoryURL = project.rootPath

        // Record the outbound prompt in the Internal Logs window.
        Task { @MainActor in
            InternalLogStore.shared.record(
                category: .ask, direction: .outbound,
                summary: "→ ask predictNext  ·  \(sourceURL.lastPathComponent):\(line + 1):\(column)",
                body: prompt
            )
        }

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // Arm a watchdog so a hung backend doesn't keep the pipe
        // open forever. terminate() releases the file handle.
        let watchdog = DispatchWorkItem { [weak task] in
            guard let task, task.isRunning else { return }
            task.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )

        task.terminationHandler = { proc in
            // Drain both pipes — `aro ask`'s native MLX backend
            // emits the actual completion to stdout but interleaves
            // backend-loading chatter (and sometimes the answer
            // itself, depending on the model) on stderr. If we only
            // looked at stdout we'd miss those cases entirely.
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let rawOut = String(data: outData, encoding: .utf8) ?? ""
            let rawErr = String(data: errData, encoding: .utf8) ?? ""
            let cleanedOut = ConsoleProcess.stripANSI(rawOut)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedErr = ConsoleProcess.stripANSI(rawErr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer stdout, fall back to stderr if stdout was empty.
            let source = cleanedOut.isEmpty ? cleanedErr : cleanedOut
            let first = source
                .components(separatedBy: "\n")
                .first ?? ""
            let stripped = first
                .replacingOccurrences(of: "|CURSOR|", with: "")
                .trimmingCharacters(in: .whitespaces)
            let trimmed = String(stripped.prefix(80))
            let exitCode = proc.terminationStatus
            DispatchQueue.main.async {
                // Log stdout as an .inbound (or .error on non-zero
                // exit). Always log stderr as a separate .info entry
                // when non-empty so the user can see what the model
                // backend was complaining about.
                let stdoutSummary: String
                if exitCode == 0 {
                    stdoutSummary = cleanedOut.isEmpty
                        ? "← ask predictNext (empty stdout — see stderr)"
                        : "← ask predictNext result"
                } else {
                    stdoutSummary = "← ask predictNext exited \(exitCode)"
                }
                InternalLogStore.shared.record(
                    category: .ask,
                    direction: exitCode == 0 ? .inbound : .error,
                    summary: stdoutSummary,
                    body: cleanedOut.isEmpty ? "(empty stdout)" : cleanedOut
                )
                if !cleanedErr.isEmpty {
                    InternalLogStore.shared.record(
                        category: .ask,
                        direction: .info,
                        summary: "← ask predictNext stderr (\(cleanedErr.count) chars)",
                        body: cleanedErr
                    )
                }
                completion(trimmed.isEmpty ? nil : trimmed)
            }
        }

        do {
            try task.run()
        } catch {
            completion(nil)
        }
    }
}
