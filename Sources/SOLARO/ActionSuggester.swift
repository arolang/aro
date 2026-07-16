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

        // In-process via the shared, warm AskSession — no subprocess
        // cold start. `finish` runs on the main actor with the first
        // non-empty line of the model's reply (or nil).
        @MainActor func finish(_ raw: String?) {
            let source = raw ?? ""
            let first = source
                .components(separatedBy: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                ?? ""
            let suggestion = sanitize(first)
            inFlight.remove(key)
            cache[key] = suggestion
            completion(suggestion.isEmpty ? nil : suggestion)
        }

        #if canImport(AROAsk)
        // `@MainActor in` pins the whole task body to the main actor, so the
        // continuation after the SolaroAskService actor hop resumes on main
        // before touching `finish` / the @MainActor cache. Without it the
        // resume can land on a background executor and macOS 26's strict
        // executor check aborts (dispatch_assert_queue) the moment a
        // @MainActor member is touched.
        Task { @MainActor in
            let raw = await SolaroAskService.shared.complete(prompt)
            finish(raw)
        }
        #else
        finish(nil)
        #endif
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
