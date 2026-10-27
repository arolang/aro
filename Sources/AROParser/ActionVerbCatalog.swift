// ============================================================
// ActionVerbCatalog.swift
// AROParser — every verb that names a built-in action
// GitLab #844
// ============================================================
//
// `aro check` accepted a statement whose verb belongs to no action:
//
//     Increment the <counter> for the <one>.
//
// checked green, and the program then died at run time with
// `unknownAction("increment")` — but only if that line was reached. The verb
// namespace is closed (`ActionRegistry` throws), exactly as the qualifier
// namespace is (GitLab #486, #465); the checker simply did not enforce it.
//
// This is not `ActionCatalog`. That one lists the verbs LLVM codegen emits an
// `@_cdecl("aro_action_<verb>")` extern for — the primary spelling of each
// action. Checking against it would reject `Calculate`, `Verify`, `Build`,
// `Print`, `Sleep`, `Commit` and fifty more real verbs. This catalog is the
// *union* of every `verbs:` set in the registry, which is the set a program
// may actually write.
//
// AROParser cannot import ARORuntime — the check path deliberately never
// loads the runtime — so the list is mirrored here, and a runtime test fails
// the build when the two drift.

import Foundation

public enum ActionVerbCatalog {

    /// Lowercase verbs of every built-in action.
    public static let allVerbs: Set<String> = [
        "accept", "aggregate", "alert", "append", "arrange", "ask", "assert",
        "attach", "await", "block", "broadcast", "build", "calculate", "call",
        "change", "check", "checkout", "choose", "clear", "clone", "close",
        "combine", "commit", "compare", "compute", "configure", "connect",
        "construct", "convert", "copy", "create", "createdirectory", "debug",
        "delay", "delete", "derive", "destroy", "disconnect", "dispatch",
        "deliver", "embed", "emit", "exec", "execute", "exists", "export", "expose",
        "extract", "fail", "fetch", "filter", "find", "flip", "get", "given",
        "group", "http", "include", "insert", "invoke", "join", "keepalive",
        "list", "listen", "load", "log", "make", "map", "match", "merge",
        "mkdir", "modify", "move", "notify", "order", "output", "parse",
        "parsehtml", "patch", "pause", "persist", "print", "probe", "prompt",
        "publish", "pull", "push", "raise", "read", "receive", "reduce",
        "remove", "rename", "render", "repaint", "request", "respond",
        "retrieve", "return", "reverse", "run", "save", "schedule", "select",
        "send", "set", "share", "shell", "show", "signal", "sleep", "sort",
        "split", "stage", "start", "stat", "stop", "store", "stream",
        "subscribe", "tag", "terminate", "then", "throw", "touch", "transform",
        "update", "validate", "verify", "wait", "when", "write"
    ]

    /// Whether a statement-initial word names a built-in action.
    ///
    /// A dotted name — `Markdown.ToHTML`, `Application.DoubleValue` — is a
    /// plugin action or a user-defined one. Neither is resolvable here
    /// (`aro check` does not load plugins, and ARO-0081 calls are validated
    /// separately against the application's own feature sets), so both are
    /// accepted.
    public static func isKnownVerb(_ verb: String) -> Bool {
        if verb.contains(".") { return true }
        return allVerbs.contains(verb.lowercased())
    }

    /// The closest known verb to a misspelling, when one is close enough to
    /// be worth naming. Edit distance 2, and only for words of four letters
    /// or more — below that, two edits reach half the catalog.
    ///
    /// Ties are broken by shared prefix and then alphabetically, and the
    /// tiebreak is the point rather than tidiness: `Retreive` is two edits
    /// from both `receive` and `retrieve`, and taking whichever the `Set`
    /// happened to yield made the suggestion change between runs of the same
    /// `aro check`. Prefix wins because a misspelling keeps its beginning —
    /// people transpose the middle of a word, not its start.
    public static func closestVerb(to verb: String) -> String? {
        let needle = verb.lowercased()
        guard needle.count >= 4 else { return nil }

        let candidates = allVerbs
            .map { (verb: $0, distance: editDistance(needle, $0)) }
            .filter { $0.distance <= 2 }
        guard !candidates.isEmpty else { return nil }

        return candidates.min { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            let aPrefix = sharedPrefixLength(needle, a.verb)
            let bPrefix = sharedPrefixLength(needle, b.verb)
            if aPrefix != bPrefix { return aPrefix > bPrefix }
            return a.verb < b.verb
        }?.verb
    }

    private static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Damerau-Levenshtein (optimal string alignment): insertion, deletion,
    /// substitution, **and** transposition of two adjacent characters.
    ///
    /// The transposition is what makes the suggestions useful. Plain
    /// Levenshtein charges `Retreive` two edits to reach `retrieve` — the
    /// same as to reach `receive`, which is a different word — and `Comptue`
    /// two to reach `compute`, tying with `compare`. Swapping two letters is
    /// the commonest typo there is, and counting it as one edit resolves both
    /// on merit instead of on a tiebreak.
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        // Three rows, because a transposition looks two back in both strings.
        var twoBack = [Int](repeating: 0, count: y.count + 1)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                var best = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    best = min(best, twoBack[j - 2] + 1)
                }
                current[j] = best
            }
            twoBack = previous
            previous = current
            current = [Int](repeating: 0, count: y.count + 1)
        }
        return previous[y.count]
    }
}
