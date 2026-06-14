// ============================================================
// ActionSuggester.swift
// SOLARO — `aro ask`-powered tailored insert lines for the
//          Actions panel hover hint (#?)
// ============================================================
//
// The Actions tab on the left rail surfaces every verb the
// project's `aro actions` knows about. The drag payload was a
// generic template (`Clear the <result> for the <input>.`) that
// gave the user no hint about which variables, bindings or
// settings would actually fit the currently-open file. This
// helper asks the local `aro ask` backend to compose a one-line
// ARO statement using a specific verb in the context of the
// file the user has open, so the hover hint can show "the line
// the user likely wants" alongside the generic template.
//
// The call is cached per (verb + file content hash) so the
// hover-dwell trigger doesn't re-spawn `aro ask` every time the
// user passes the same row.

import Foundation

@MainActor
enum ActionSuggester {
    /// Memoise across hovers. Key encodes the verb + a short
    /// hash of the file contents at the time of the request so
    /// edits invalidate naturally. Bounded by the dictionary's
    /// natural growth — Actions tab has on the order of 70 verbs
    /// and the user rarely touches every one in a session, so a
    /// hard cap isn't worth the complexity yet.
    private static var cache: [String: String] = [:]
    /// Track in-flight requests so a quick re-hover within the
    /// dwell window doesn't trigger a second `aro ask` for the
    /// same (verb, source) pair.
    private static var inFlight: Set<String> = []

    /// Fetch — or return — a one-line ARO statement that uses
    /// `verb` in the context of `sourceURL`. Calls the completion
    /// closure on the main actor when the model responds, or
    /// with `nil` on any error / timeout / cancellation.
    static func suggest(
        verb: String,
        template: String,
        sourceURL: URL,
        project: Project,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        guard let text = try? String(contentsOf: sourceURL, encoding: .utf8)
        else { completion(nil); return }
        let key = cacheKey(verb: verb, source: text)
        if let cached = cache[key] {
            completion(cached.isEmpty ? nil : cached)
            return
        }
        if inFlight.contains(key) {
            // Another hover is already fetching this combination;
            // don't pile on. The first call will populate `cache`
            // and the next hover will read it back.
            completion(nil)
            return
        }
        inFlight.insert(key)

        let prompt = buildPrompt(verb: verb, template: template, source: text)
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
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        // 12s watchdog — long enough for the cold start of the
        // local model on a fast machine, short enough that the
        // tooltip doesn't sit empty forever on a hung backend.
        let timeout: TimeInterval = 12.0
        let watchdog = DispatchWorkItem { [weak task] in
            guard let task, task.isRunning else { return }
            task.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout, execute: watchdog
        )

        task.terminationHandler = { proc in
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let rawOut = String(data: outData, encoding: .utf8) ?? ""
            let rawErr = String(data: errData, encoding: .utf8) ?? ""
            let cleanedOut = ConsoleProcess.stripANSI(rawOut)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanedErr = ConsoleProcess.stripANSI(rawErr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let source = cleanedOut.isEmpty ? cleanedErr : cleanedOut
            // Take the first non-empty line; that's the statement.
            let first = source
                .components(separatedBy: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? ""
            let suggestion = sanitize(first)
            DispatchQueue.main.async {
                inFlight.remove(key)
                cache[key] = suggestion
                completion(suggestion.isEmpty ? nil : suggestion)
            }
        }

        do {
            try task.run()
        } catch {
            inFlight.remove(key)
            completion(nil)
        }
    }

    /// Trim wrapper backticks / code fences the model sometimes
    /// emits despite the instruction. Keeps only printable ASCII
    /// + the small set of ARO-relevant punctuation; everything
    /// past the first 120 chars is dropped so a rambling reply
    /// can't blow up the tooltip layout.
    nonisolated private static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("`") { s.removeFirst() }
        while s.hasSuffix("`") { s.removeLast() }
        return String(s.prefix(120))
    }

    private static func buildPrompt(
        verb: String,
        template: String,
        source: String
    ) -> String {
        // Cap the source we ship to ~80 lines so a long file
        // doesn't dominate the prompt budget. The model only
        // needs enough context to read the bindings in scope.
        let lines = source.components(separatedBy: "\n")
        let cap = 80
        let trimmed = lines.count > cap
            ? lines.prefix(cap).joined(separator: "\n") + "\n…"
            : source
        return """
        You're an inline-suggestion assistant for the ARO language.
        Produce ONE ARO statement that uses the action `\(verb)` and
        would slot naturally into the file below. Use the same
        variable / binding names that are already in scope — don't
        invent unrelated names. Output ONLY the statement on a
        single line, no quotes, no fences, no prose. Maximum 120
        characters. End with a period.

        Generic template for `\(verb)`:
        \(template)

        File under edit:
        \(trimmed)
        """
    }

    private static func cacheKey(verb: String, source: String) -> String {
        // FNV-1a hash over the source — cheap, collision rate
        // good enough for an in-process memo table.
        var hash: UInt64 = 0xCBF29CE484222325
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001B3
        }
        return "\(verb.lowercased()):\(String(hash, radix: 16))"
    }
}
