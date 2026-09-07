// ============================================================
// GraphDiff.swift
// AROParser — feature-set / statement level diff (GitLab #443)
// ============================================================
//
// A textual diff of an .aro file answers "which lines changed".
// The question people actually have about a merge request is
// "which *feature sets* changed, and what happened inside them" —
// a statement moving three lines down because something was
// inserted above it is noise, and a `Return` whose status changed
// from OK to Created is not.
//
// So this diffs the parsed programs, not the bytes: feature sets
// are matched by name, statements inside a matched pair are
// matched by an LCS over their rendered form, and an adjacent
// remove/add of the same verb collapses into one `modified` entry
// instead of reading as an unrelated deletion plus insertion.
//
// It lives in AROParser because it's pure AST analysis with no
// runtime or UI dependency: `aro diff --graph` and SOLARO's
// side-by-side graph view are both callers.

import Foundation

/// A source file indexed for span slicing.
///
/// `SourceLocation.offset` counts characters, so slicing a span
/// needs random access into the file. Building the index once per
/// file keeps rendering a feature set linear instead of quadratic.
public struct SourceText: Sendable {
    private let characters: [Character]

    public init(_ text: String) {
        characters = Array(text)
    }

    /// The text a span covers, whitespace collapsed, or nil when
    /// the span cannot be trusted — a synthesised node with no real
    /// extent, or offsets past the end of the file because the
    /// caller paired a statement with the wrong source. Callers
    /// fall back to the AST description rather than show a wrong
    /// or empty line.
    public func slice(_ span: SourceSpan) -> String? {
        let start = span.start.offset
        var end = span.end.offset
        guard start >= 0, end > start, end <= characters.count else { return nil }
        // A statement's span stops at its last token, so the
        // terminating period is one character past the end. Take
        // it: a rendered ARO statement without its period isn't a
        // statement, it's a fragment.
        if end < characters.count, characters[end] == "." { end += 1 }
        let text = Self.collapseWhitespace(String(characters[start..<end]))
        return text.isEmpty ? nil : text
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// What happened to a feature set or a statement between two
/// revisions.
public enum GraphChange: String, Sendable, Hashable, CaseIterable {
    case added
    case removed
    case modified
    case unchanged
}

/// One statement's fate.
public struct StatementDiff: Sendable, Hashable {
    public let change: GraphChange
    /// Rendered statement on the "before" side, nil when added.
    public let before: String?
    /// Rendered statement on the "after" side, nil when removed.
    public let after: String?
    public let beforeLine: Int?
    public let afterLine: Int?
    /// Verb of whichever side exists — what the node card shows.
    public let verb: String

    public init(change: GraphChange, before: String?, after: String?,
                beforeLine: Int?, afterLine: Int?, verb: String) {
        self.change = change
        self.before = before
        self.after = after
        self.beforeLine = beforeLine
        self.afterLine = afterLine
        self.verb = verb
    }

    /// Text to show on a node card: the after side when there is
    /// one, otherwise what was removed.
    public var display: String { after ?? before ?? "" }
}

/// One feature set's fate, plus what happened inside it.
public struct FeatureSetDiff: Sendable, Hashable {
    public let name: String
    public let businessActivity: String
    public let change: GraphChange
    public let statements: [StatementDiff]

    public init(name: String, businessActivity: String,
                change: GraphChange, statements: [StatementDiff]) {
        self.name = name
        self.businessActivity = businessActivity
        self.change = change
        self.statements = statements
    }

    public func count(of change: GraphChange) -> Int {
        statements.filter { $0.change == change }.count
    }

    /// True when nothing inside changed. Drives the "collapse
    /// untouched feature sets" default in the graph view — a merge
    /// request that touches one feature set shouldn't render forty.
    public var isUntouched: Bool { change == .unchanged }
}

/// The whole comparison.
public struct AROGraphDiff: Sendable, Hashable {
    public let featureSets: [FeatureSetDiff]

    public init(featureSets: [FeatureSetDiff]) {
        self.featureSets = featureSets
    }

    public func featureSets(_ change: GraphChange) -> [FeatureSetDiff] {
        featureSets.filter { $0.change == change }
    }

    /// Statement-level totals across every feature set.
    public func statementCount(of change: GraphChange) -> Int {
        featureSets.reduce(0) { $0 + $1.count(of: change) }
    }

    /// True when the two revisions are the same graph.
    public var isEmpty: Bool { featureSets.allSatisfy(\.isUntouched) }

    /// One-line summary for a CLI header or a status bar.
    public var summaryLine: String {
        let added = statementCount(of: .added)
        let removed = statementCount(of: .removed)
        let modified = statementCount(of: .modified)
        let touched = featureSets.filter { !$0.isUntouched }.count
        return "\(touched) feature set\(touched == 1 ? "" : "s") touched · "
            + "+\(added) −\(removed) ~\(modified)"
    }

    // MARK: - Comparison

    /// Diff two parsed programs. Either side may be nil — a file
    /// that didn't exist on one side is wholly added or removed.
    public static func compare(before: Program?, after: Program?) -> AROGraphDiff {
        let beforeSets = before?.featureSets ?? []
        let afterSets = after?.featureSets ?? []

        var beforeByName: [String: FeatureSet] = [:]
        for set in beforeSets { beforeByName[set.name] = set }
        var afterByName: [String: FeatureSet] = [:]
        for set in afterSets { afterByName[set.name] = set }

        var diffs: [FeatureSetDiff] = []

        // Walk the "after" order first so the result reads like the
        // new file; removed sets are appended in their old order.
        for set in afterSets {
            if let old = beforeByName[set.name] {
                let statements = diffStatements(before: old, after: set)
                let changed = statements.contains { $0.change != .unchanged }
                    || old.businessActivity != set.businessActivity
                diffs.append(FeatureSetDiff(
                    name: set.name,
                    businessActivity: set.businessActivity,
                    change: changed ? .modified : .unchanged,
                    statements: statements))
            } else {
                diffs.append(FeatureSetDiff(
                    name: set.name,
                    businessActivity: set.businessActivity,
                    change: .added,
                    statements: set.statements.map {
                        StatementDiff(
                            change: .added,
                            before: nil,
                            after: render($0),
                            beforeLine: nil,
                            afterLine: $0.span.start.line,
                            verb: verb(of: $0))
                    }))
            }
        }

        for set in beforeSets where afterByName[set.name] == nil {
            diffs.append(FeatureSetDiff(
                name: set.name,
                businessActivity: set.businessActivity,
                change: .removed,
                statements: set.statements.map {
                    StatementDiff(
                        change: .removed,
                        before: render($0),
                        after: nil,
                        beforeLine: $0.span.start.line,
                        afterLine: nil,
                        verb: verb(of: $0))
                }))
        }

        return AROGraphDiff(featureSets: diffs)
    }

    // MARK: - Statement matching

    /// LCS diff over rendered statements, then collapse a
    /// removed/added pair sharing a verb into one `modified`.
    ///
    /// `beforeSource` / `afterSource` are the files the two sides
    /// were parsed from. When given, statements render as the code
    /// the author actually wrote instead of the AST's debug form —
    /// a reviewer reads `Return a <Created: status> with <user>.`,
    /// not `<Return> the <Created: status> with the <_expression_>`.
    static func diffStatements(before: FeatureSet, after: FeatureSet,
                               beforeSource: SourceText? = nil,
                               afterSource: SourceText? = nil) -> [StatementDiff]
    {
        let old = before.statements
        let new = after.statements
        let oldText = old.map { render($0, in: beforeSource) }
        let newText = new.map { render($0, in: afterSource) }

        let common = lcsTable(oldText, newText)
        var raw: [StatementDiff] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if oldText[i] == newText[j] {
                raw.append(StatementDiff(
                    change: .unchanged,
                    before: oldText[i], after: newText[j],
                    beforeLine: old[i].span.start.line,
                    afterLine: new[j].span.start.line,
                    verb: verb(of: new[j])))
                i += 1
                j += 1
            } else if common[i + 1][j] >= common[i][j + 1] {
                raw.append(StatementDiff(
                    change: .removed,
                    before: oldText[i], after: nil,
                    beforeLine: old[i].span.start.line, afterLine: nil,
                    verb: verb(of: old[i])))
                i += 1
            } else {
                raw.append(StatementDiff(
                    change: .added,
                    before: nil, after: newText[j],
                    beforeLine: nil, afterLine: new[j].span.start.line,
                    verb: verb(of: new[j])))
                j += 1
            }
        }
        while i < old.count {
            raw.append(StatementDiff(
                change: .removed,
                before: oldText[i], after: nil,
                beforeLine: old[i].span.start.line, afterLine: nil,
                verb: verb(of: old[i])))
            i += 1
        }
        while j < new.count {
            raw.append(StatementDiff(
                change: .added,
                before: nil, after: newText[j],
                beforeLine: nil, afterLine: new[j].span.start.line,
                verb: verb(of: new[j])))
            j += 1
        }

        return collapseModifications(raw)
    }

    /// A statement whose object changed reads as remove-then-add in
    /// a line diff. On a graph that would delete a node and draw a
    /// new one, losing its position and any comment anchored to it,
    /// so a removed/added pair sharing a verb becomes one node
    /// marked `modified`.
    ///
    /// The pairing runs over a whole *run* of changed entries, not
    /// just adjacent ones. LCS emits every deletion in a run before
    /// every insertion, so editing two statements and inserting a
    /// third between them produced three deletions facing three
    /// insertions — six nodes churned where two were edited. Within
    /// a run each removal takes the first still-unclaimed insertion
    /// with the same verb, in order, and what is left over stays a
    /// plain removal or insertion.
    static func collapseModifications(_ raw: [StatementDiff]) -> [StatementDiff] {
        var out: [StatementDiff] = []
        var index = 0
        while index < raw.count {
            guard raw[index].change != .unchanged else {
                out.append(raw[index])
                index += 1
                continue
            }
            // Take the maximal run of changed entries.
            var end = index
            while end < raw.count, raw[end].change != .unchanged { end += 1 }
            out.append(contentsOf: pairRun(Array(raw[index..<end])))
            index = end
        }
        return out
    }

    /// Pair the removals and insertions of one run by verb.
    private static func pairRun(_ run: [StatementDiff]) -> [StatementDiff] {
        let insertions = run.filter { $0.change == .added }
        var claimed = Array(repeating: false, count: insertions.count)
        var out: [StatementDiff] = []

        for entry in run where entry.change == .removed {
            let match = insertions.indices.first {
                !claimed[$0] && insertions[$0].verb.lowercased() == entry.verb.lowercased()
            }
            guard let match else {
                out.append(entry)
                continue
            }
            claimed[match] = true
            let insertion = insertions[match]
            out.append(StatementDiff(
                change: .modified,
                before: entry.before,
                after: insertion.after,
                beforeLine: entry.beforeLine,
                afterLine: insertion.afterLine,
                verb: entry.verb))
        }
        // Genuinely new statements keep their order, after the
        // statements they were interleaved with.
        for index in insertions.indices where !claimed[index] {
            out.append(insertions[index])
        }
        return out
    }

    /// Standard LCS length table, `[i][j]` = LCS of the suffixes.
    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(
            repeating: Array(repeating: 0, count: b.count + 1),
            count: a.count + 1)
        guard !a.isEmpty, !b.isEmpty else { return table }
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        return table
    }

    // MARK: - Statement rendering

    /// Canonical text for matching and for display. Whitespace is
    /// collapsed so a re-indent doesn't read as a change — the
    /// graph doesn't care about columns.
    ///
    /// With the file the statement was parsed from, this is the
    /// source the author wrote, sliced by the statement's span.
    /// Without it, the AST's debug description — correct for
    /// matching, but it renders modifiers as `<_expression_>`
    /// placeholders, which is not something anyone typed.
    public static func render(_ statement: any Statement, in source: SourceText? = nil) -> String {
        if let slice = source?.slice(statement.span) { return slice }
        return SourceText.collapseWhitespace(statement.description)
    }

    /// Convenience for a caller holding a plain string. Indexing
    /// costs a pass over the file, so a caller rendering many
    /// statements should build one `SourceText` and reuse it.
    public static func render(_ statement: any Statement, in source: String) -> String {
        render(statement, in: SourceText(source))
    }

    /// Verb for pairing and for the node card. Non-ARO statements
    /// (Publish, ForEach, …) report their type name instead.
    public static func verb(of statement: any Statement) -> String {
        if let aro = statement as? AROStatement {
            return aro.action.verb
        }
        return String(describing: type(of: statement))
            .replacingOccurrences(of: "Statement", with: "")
    }
}
