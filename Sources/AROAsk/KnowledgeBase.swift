// ============================================================
// KnowledgeBase.swift
// AROAsk - how ARO does things, answerable offline
// ============================================================
//
// The 6-bit local model knows ARO's shape but not its idioms, and the
// difference shows exactly where /fix needs it: what a diagnostic means,
// which repair is canonical, and which repairs are traps (deleting a
// binding that a `for` bound reads, appending a handler that exists in a
// sibling file). This is that knowledge, curated from the proposals and
// CLAUDE.md, keyword-searchable, and shipped in the binary so it works
// offline like the model does.
//
// Two consumers:
//   * the `aro_knowledge` tool — the model can ask "how does ARO do X?"
//     mid-conversation and get the idiom instead of inventing one;
//   * the /fix loop — each diagnostic class pulls its entry and the fix
//     prompt carries it, so the model repairs with the idiom in front of
//     it rather than from memory.

import Foundation

/// One fact about how ARO does something.
public struct KnowledgeEntry: Sendable {
    /// Stable identifier, also useful in tests.
    public let id: String
    /// Lowercased match terms. Multi-word topics score higher when they
    /// match whole, so "no handler exists" beats three stray words.
    public let topics: [String]
    /// The canonical answer, written to be pasted into a model prompt.
    public let answer: String
}

public enum AROKnowledgeBase {

    // MARK: - Lookup

    /// Best entries for a free-form question, most relevant first.
    ///
    /// Scoring is deliberately dumb: phrase hits (a whole multi-word topic
    /// appearing in the question) weigh 3, single-word topic hits weigh 1.
    /// Dumb is a feature — it runs identically everywhere, needs no index,
    /// and its failure mode is "no answer", never a wrong one.
    public static func lookup(_ question: String, limit: Int = 2) -> [KnowledgeEntry] {
        let q = question.lowercased()
        let words = Set(q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        let scored: [(KnowledgeEntry, Int)] = entries.compactMap { entry in
            var score = 0
            for topic in entry.topics {
                if topic.contains(" ") {
                    if q.contains(topic) { score += 3 }
                } else if words.contains(topic) {
                    score += 1
                }
            }
            return score > 0 ? (entry, score) : nil
        }

        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Entries matched to an `aro check` report — the /fix loop's entry
    /// point. Every diagnostic class present contributes its knowledge once.
    public static func forCheckReport(_ report: String) -> [KnowledgeEntry] {
        var matched: [KnowledgeEntry] = []
        func add(_ id: String) {
            guard let entry = entries.first(where: { $0.id == id }),
                  !matched.contains(where: { $0.id == entry.id }) else { return }
            matched.append(entry)
        }

        if report.contains("is emitted but no handler exists") { add("unhandled-event") }
        if report.contains("is defined but never used") { add("unused-variable") }
        if report.contains("Unknown Compute qualifier") { add("compute-qualifiers") }
        if report.contains("error:") { add("statement-shape") }
        return matched
    }

    // MARK: - Entries

    public static let entries: [KnowledgeEntry] = [
        KnowledgeEntry(
            id: "unhandled-event",
            topics: ["no handler exists", "unhandled event", "emit", "handler", "event"],
            answer: """
            "Event 'X' is emitted but no handler exists" — an ARO application \
            has NO imports: every feature set in every .aro file of the \
            directory is globally visible, and handlers routinely live in a \
            different file from the Emit (storage.aro, links.aro, ...). So \
            FIRST search every file for a feature set whose business activity \
            is exactly "X Handler", e.g. `(Save Page: SavePage Handler) { ... }`. \
            If one exists anywhere, the warning is stale — change nothing. \
            Only if none exists anywhere, APPEND a new feature set (never \
            rewrite existing code):

            (Handle X: X Handler) {
                Extract the <field> from the <event: field>.
                Return an <OK: status> for the <handled>.
            }

            Extract exactly the fields the Emit passes. One handler silences \
            every Emit of that event — never add a second one.
            """
        ),
        KnowledgeEntry(
            id: "unused-variable",
            topics: ["defined but never used", "unused variable", "unused", "variable"],
            answer: """
            "Variable 'v' is defined but never used" — before deleting \
            anything, search the WHOLE file for later reads of <v>: loop \
            bounds (`for <i> from 0 to <v>`), `when` guards, string \
            interpolation `${<v>}`, and qualifier bases all read it. If it is \
            read anywhere, the warning is wrong — change nothing and say so. \
            If it is genuinely unread, delete ONLY the one statement that \
            binds it, byte-for-byte leaving every other line. If that binding \
            is the only statement inside a `case` or loop block, delete the \
            enclosing block header and closing brace with it — an empty block \
            does not parse. Never rename, reformat or "tidy" anything else.
            """
        ),
        KnowledgeEntry(
            id: "compute-qualifiers",
            topics: ["unknown compute qualifier", "qualifier", "compute"],
            answer: """
            The Compute qualifier namespace is CLOSED. A qualifier must be a \
            built-in (length, uppercase, trim, sum, avg, unique, sha256, \
            base64-encode, url-encode, lines, join, replace, html-escape, ...), \
            a plugin qualifier (handle.name), a chain (a|b), or a date offset \
            (-7d). An invented name is an error. Sorting and reversing are \
            ACTIONS, not qualifiers: `Sort the <s> for the <x>.`, \
            `Reverse the <r> for the <x>.`. Element access is an Extract: \
            `Extract the <f: first> from the <x>.`. A result type uses `as`: \
            `Compute the <n> as Float from <s>.`. To count lines: qualifier \
            `lines` then `length`.
            """
        ),
        KnowledgeEntry(
            id: "statement-shape",
            topics: ["syntax", "statement", "parse error", "expected", "action verb"],
            answer: """
            Every ARO statement is `Verb the <result> preposition the \
            <object>.` — one verb, one result in angle brackets, one \
            preposition, one object, a trailing period. Articles are \
            optional; spacing inside a statement is NOT significant syntax, \
            so `the<name>` and `the <name>` are both valid — when repairing, \
            copy unfixed lines byte-for-byte rather than normalising them. \
            `<a>< <b>` is a comparison (`<a> < <b>`) written tightly; do not \
            "fix" it. Feature sets are `(Name: Business Activity) { ... }`. \
            Event handlers use business activity `X Handler`; HTTP routes use \
            the operationId from openapi.yaml.
            """
        ),
        KnowledgeEntry(
            id: "cross-file-visibility",
            topics: ["imports", "visibility", "files", "application", "structure", "directory"],
            answer: """
            An ARO application is a directory. ALL .aro files in it (and \
            subdirectories) are compiled together; every feature set is \
            visible to every other one with no imports. Handlers, routes and \
            actions may live in any file. Consequences: never duplicate a \
            feature set that exists in a sibling file, and answer "does a \
            handler/route exist?" by searching the whole directory, not one \
            file. Exactly one Application-Start exists per application.
            """
        ),
        KnowledgeEntry(
            id: "immutability",
            topics: ["immutable", "rebind", "reassign", "compare", "mutation"],
            answer: """
            Bindings are immutable — a name is bound once per scope. To \
            derive a value, bind a NEW name (qualifier-as-name): \
            `Compute the <clean: trim> from <raw>.`. Compare binds a fresh \
            result: `Compare the <same> from the <a> against the <b>.` then \
            read `<same: matches>` (boolean) or `<same: result>` \
            (equal/less/greater). Never write a statement that rebinds an \
            existing name.
            """
        ),
        KnowledgeEntry(
            id: "iteration",
            topics: ["loop", "for each", "repeat", "map", "iterate", "range"],
            answer: """
            Per-element computation uses `for each <item> in <list> { ... }`. \
            `Map the <ns> from the <us> with name.` projects a FIELD — `with` \
            takes a field name, never an expression. Repeat-n-times is \
            `for <i> from 0 to <n> { ... }`; an unread counter there is \
            idiomatic, not a defect. `parallel for each` runs iterations \
            concurrently.
            """
        ),
        KnowledgeEntry(
            id: "error-philosophy",
            topics: ["error", "handling", "try", "catch", "validation", "happy"],
            answer: """
            ARO code contains only the happy case — there is no try/catch and \
            no error branch to write. The runtime reports failures itself \
            ("Can not retrieve the user from the user-repository where id = \
            530"). Do not add defensive checks, null guards or error \
            handlers; a repair that introduces them is wrong. `when` guards \
            express business conditions, not error handling.
            """
        ),
    ]
}
