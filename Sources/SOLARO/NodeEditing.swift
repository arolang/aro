// ============================================================
// NodeEditing.swift
// SOLARO — double-click a canvas node to edit its statement
// ============================================================
//
// Per-action editor presets layered on top of a single shared
// protocol (`NodeEditingSchema`). Double-clicking a canvas node
// expands the card into the schema's editor; the user fills the
// fields, hits Apply, and the new statement text is written back
// to the .aro file by replacing the AROStatement's source span.
//
// Every action verb has a preset that knows which fields make
// sense for that verb (Log → message + target, Create → result +
// expression, anything with `with { … }` → key/value table, …),
// and falls back to a generic raw-text editor when the verb isn't
// recognised. The schemas are tiny value types so adding a new
// preset means writing one struct and one `case` in `infer`.

import SwiftUI
import AROParser

// MARK: - Field model

/// A single editable input rendered in the node editor. Schemas
/// describe themselves as an ordered list of fields.
enum EditableField: Identifiable, Equatable {
    /// Plain string literal (the message argument of a Log, an
    /// event name, a URL, …). Stored verbatim into the source —
    /// quotes are added around it on apply.
    case stringLiteral(id: String, label: String, value: String,
                       placeholder: String)
    /// A bare identifier slot like `<user>` — the value is rendered
    /// inside angle brackets when written back. `suggestions`
    /// drives the variable-picker dropdown.
    case identifier(id: String, label: String, value: String,
                    suggestions: [String])
    /// Any expression — kept as raw source. Used for Compute, the
    /// "with" payload of Emit, etc.
    case expression(id: String, label: String, value: String,
                    placeholder: String)
    /// A picker from a fixed enum of literal options (e.g. status
    /// kinds: OK / Created / Error).
    case picker(id: String, label: String, value: String,
                options: [String])
    /// A key/value table — the `with { key: expression, … }` clause.
    /// Each row is one record entry.
    case record(id: String, label: String, rows: [RecordRow])
    /// A free-text field with a dropdown of suggested values —
    /// used for the qualifier slot in `<name: qualifier>` (#?). The
    /// dropdown is populated from `QualifierCatalog.snapshot()` so
    /// plugin-registered qualifiers appear automatically. Empty
    /// `value` means "no qualifier" and the renderer omits the
    /// colon suffix.
    case combo(id: String, label: String, value: String,
               placeholder: String, options: [QualifierOption])
    /// A vertical list of expressions — the items of a `[ … ]`
    /// array literal. Each row is one element (string literal,
    /// number, identifier, …) kept as raw source so quotes and
    /// brackets round-trip verbatim. Apply emits the items joined
    /// by `,\n    ` inside `[ … ]`.
    case list(id: String, label: String, items: [ListItem],
              placeholder: String)

    var id: String {
        switch self {
        case .stringLiteral(let id, _, _, _),
             .identifier(let id, _, _, _),
             .expression(let id, _, _, _),
             .picker(let id, _, _, _),
             .record(let id, _, _),
             .combo(let id, _, _, _, _),
             .list(let id, _, _, _):
            return id
        }
    }
}

/// One row in a `.list` field — a single element of a `[ … ]`
/// array literal. The value is the raw source text (e.g. with
/// quotes), so an item like `"http://…"` is stored verbatim.
struct ListItem: Identifiable, Equatable {
    let id: UUID
    var value: String

    init(value: String) {
        self.id = UUID()
        self.value = value
    }
}

struct RecordRow: Identifiable, Equatable {
    let id: UUID
    var key: String
    var value: String

    init(key: String, value: String) {
        self.id = UUID()
        self.key = key
        self.value = value
    }
}

// MARK: - Schema protocol

/// What can be edited in a given action node, plus how to render
/// its new source text once the user hits Apply.
protocol NodeEditingSchema {
    /// Short headline above the editor — usually the verb + result
    /// (e.g. `"Edit Log statement"`).
    var title: String { get }
    /// One-liner describing what's editable. Optional.
    var subtitle: String? { get }
    /// Ordered list of fields to render.
    var fields: [EditableField] { get set }
    /// Compose the new statement source from the current `fields`
    /// state. Returns `nil` if the inputs aren't valid yet so the
    /// editor can disable Apply.
    func render() -> String?
}

extension NodeEditingSchema {
    var subtitle: String? { nil }
}

// MARK: - Per-action presets

/// `Log <message> to the <target>.` Optionally trailed by a
/// `when <expression>` guard.
struct LogEditing: NodeEditingSchema {
    var title: String { "Edit Log statement" }
    var subtitle: String? { "Message to print, plus the target sink." }
    var fields: [EditableField]

    func render() -> String? {
        guard let msg = fields.firstString("message"),
              let target = fields.firstIdentifier("target"),
              !target.isEmpty else { return nil }
        let escaped = msg.replacingOccurrences(of: "\"", with: "\\\"")
        let when = appendWhen(fields)
        return "Log \"\(escaped)\" to the <\(target)>\(when)."
    }
}

/// Helper used by every schema with an optional `when` clause —
/// returns the trailing ` when …` string (with leading space) or
/// the empty string when the guard field is blank.
private func appendWhen(_ fields: [EditableField]) -> String {
    let expr = fields.firstExpression("when")?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return expr.isEmpty ? "" : " when \(expr)"
}

/// Composes `name` and optional `modifier` into the canonical
/// `<name>` / `<name: modifier>` form. Centralised so every
/// schema that splits an identifier into the name + modifier
/// pair renders it the same way.
private func renderTaggedIdentifier(name: String, modifier: String?) -> String? {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !n.isEmpty else { return nil }
    let m = (modifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return m.isEmpty ? "<\(n)>" : "<\(n): \(m)>"
}

/// `Create the <result> with <expression>.` — handles two shapes:
/// a plain expression (Compute-style) and a list literal (the
/// `with [ a, b, c ]` shape). The factory picks which field
/// flavor to install; `render()` reads whichever is present.
struct CreateEditing: NodeEditingSchema {
    var title: String { "Edit Create statement" }
    var subtitle: String? { "Name of the new binding, an optional modifier, and its value expression." }
    var fields: [EditableField]

    func render() -> String? {
        guard let result = fields.firstIdentifier("result"),
              !result.isEmpty else { return nil }
        let modifier = fields.firstCombo("modifier")
        guard let tagged = renderTaggedIdentifier(name: result,
                                                  modifier: modifier)
        else { return nil }
        let when = appendWhen(fields)
        // List flavor wins when present — the factory only adds it
        // when the original statement was `with [ … ]`, so picking
        // it back here is unambiguous.
        if let items = fields.firstList("expression") {
            let body = renderListItems(items)
            return "Create the \(tagged) with \(body)\(when)."
        }
        guard let expr = fields.firstExpression("expression"),
              !expr.isEmpty else { return nil }
        return "Create the \(tagged) with \(expr)\(when)."
    }
}

/// Render `[ item1, item2, … ]` with one item per line — matches
/// the convention used in the canonical examples (see
/// `Examples/UptimeMonitor/main.aro`). Empty / whitespace-only
/// rows are dropped so the user can leave an unfinished blank
/// row in the editor without it polluting the output.
private func renderListItems(_ items: [ListItem]) -> String {
    let cleaned = items
        .map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if cleaned.isEmpty { return "[]" }
    let joined = cleaned.joined(separator: ",\n        ")
    return "[\n        \(joined)\n    ]"
}

/// `Compute the <result: qualifier> from <expression>.` —
/// same shape as Create but reads more naturally with `from`,
/// and the qualifier is the common case for builtin Compute
/// operations (`length`, `uppercase`, …).
struct ComputeEditing: NodeEditingSchema {
    var title: String { "Edit Compute statement" }
    var subtitle: String? { "Derived binding name, an optional qualifier, and the expression it's computed from." }
    var fields: [EditableField]

    func render() -> String? {
        guard let result = fields.firstIdentifier("result"),
              let expr = fields.firstExpression("expression"),
              !result.isEmpty,
              !expr.isEmpty else { return nil }
        let modifier = fields.firstCombo("modifier")
        guard let tagged = renderTaggedIdentifier(name: result,
                                                  modifier: modifier)
        else { return nil }
        let when = appendWhen(fields)
        return "Compute the \(tagged) from \(expr)\(when)."
    }
}

/// `Return a <status: status> for the <subject>.` — status is
/// picked from a small enum so the user can't typo it.
struct ReturnEditing: NodeEditingSchema {
    var title: String { "Edit Return statement" }
    var subtitle: String? { "Response status and the subject it refers to." }
    var fields: [EditableField]

    static let statusOptions = [
        "OK", "Created", "Accepted", "NoContent",
        "BadRequest", "Unauthorized", "NotFound", "Conflict", "Error"
    ]

    func render() -> String? {
        guard let status = fields.firstPicker("status"),
              let subject = fields.firstIdentifier("subject"),
              !status.isEmpty,
              !subject.isEmpty else { return nil }
        let article = "aeiouAEIOU".contains(status.first ?? " ") ? "an" : "a"
        let when = appendWhen(fields)
        return "Return \(article) <\(status): status> for the <\(subject)>\(when)."
    }
}

/// `Emit a <Name: event> with <expression>.` — event name as a
/// bare identifier, payload as a free-form expression.
struct EmitEditing: NodeEditingSchema {
    var title: String { "Edit Emit statement" }
    var subtitle: String? { "Event name and payload to publish." }
    var fields: [EditableField]

    func render() -> String? {
        guard let name = fields.firstIdentifier("event"),
              let payload = fields.firstExpression("payload"),
              !name.isEmpty,
              !payload.isEmpty else { return nil }
        let when = appendWhen(fields)
        return "Emit a <\(name): event> with \(payload)\(when)."
    }
}

/// `<verb> the <result> [<prep> the <object>] with { key1: value1, … }.`
/// — the kind of statement that takes a record literal. Used for any
/// verb whose "with" clause is an object expression. The optional
/// object slot (e.g. `from <git>` for Clone, `to <user-repository>`
/// for Store) was being dropped by an earlier version of this
/// schema; it's now captured as metadata at infer time and
/// re-emitted on apply so the object phrase round-trips.
///
/// Multi-line `with { … }` bodies: anything with two or more
/// non-empty entries renders one entry per line at +4 columns of
/// indent. Matches how the language guide formats record literals
/// and what the user typed by hand before they opened the editor.
struct WithClauseEditing: NodeEditingSchema {
    var title: String { "Edit \(verb) statement" }
    var subtitle: String? { "Each row becomes one entry in the `with { … }` record." }
    let verb: String
    /// Captured object slot (`prep` + object identifier) lifted off
    /// the source AST. nil when the original statement had no
    /// object — Log "msg" to the <console> style verbs always have
    /// one, but a bare `Render the <out>` does not.
    let objectPreposition: String?
    let objectName: String?
    let objectModifier: String?
    var fields: [EditableField]

    func render() -> String? {
        guard let result = fields.firstIdentifier("result"),
              !result.isEmpty,
              let rows = fields.firstRecord("entries") else { return nil }
        let pairs = rows
            .filter { !$0.key.isEmpty && !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
        let body: String
        if pairs.isEmpty {
            body = "{}"
        } else if pairs.count == 1 {
            body = "{ \(pairs[0]) }"
        } else {
            // Multi-line: one entry per row at +4 cols, closing
            // brace lined up with the verb. Indent uses 4 spaces
            // to match `AROFormatter.indentWidth`; the formatter
            // will rebalance afterwards if the surrounding context
            // is deeper.
            let joined = pairs.joined(separator: ",\n        ")
            body = "{\n        \(joined)\n    }"
        }
        let objectPhrase = renderObjectPhrase()
        return "\(verb) the <\(result)>\(objectPhrase) with \(body)."
    }

    /// Re-emit the `prep the <object[: modifier]>` slot, with a
    /// leading space. Object name comes from the editable
    /// identifier field (so the user can pick a different binding
    /// from the suggestions dropdown); preposition + modifier
    /// stay captured metadata so the round-trip is faithful when
    /// the user only changes the object name.
    private func renderObjectPhrase() -> String {
        guard let prep = objectPreposition?
                .trimmingCharacters(in: .whitespaces),
              !prep.isEmpty
        else { return "" }
        let name = (fields.firstIdentifier("object")
                    ?? objectName ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "" }
        let modifier = objectModifier?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let tagged = modifier.isEmpty
            ? "<\(name)>"
            : "<\(name): \(modifier)>"
        return " \(prep) the \(tagged)"
    }
}

/// Last-resort editor — shows the raw source as a single
/// multi-line text field. Used for actions we haven't built a
/// preset for yet.
struct GenericEditing: NodeEditingSchema {
    var title: String { "Edit statement" }
    var subtitle: String? { "Free-form source. Edit the statement text directly." }
    var fields: [EditableField]

    func render() -> String? {
        guard let raw = fields.firstExpression("raw") else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Field lookup helpers

private extension Array where Element == EditableField {
    func firstString(_ id: String) -> String? {
        for f in self {
            if case let .stringLiteral(fid, _, value, _) = f, fid == id {
                return value
            }
        }
        return nil
    }

    func firstIdentifier(_ id: String) -> String? {
        for f in self {
            if case let .identifier(fid, _, value, _) = f, fid == id {
                return value
            }
        }
        return nil
    }

    func firstExpression(_ id: String) -> String? {
        for f in self {
            if case let .expression(fid, _, value, _) = f, fid == id {
                return value
            }
        }
        return nil
    }

    func firstPicker(_ id: String) -> String? {
        for f in self {
            if case let .picker(fid, _, value, _) = f, fid == id {
                return value
            }
        }
        return nil
    }

    func firstRecord(_ id: String) -> [RecordRow]? {
        for f in self {
            if case let .record(fid, _, rows) = f, fid == id { return rows }
        }
        return nil
    }

    func firstCombo(_ id: String) -> String? {
        for f in self {
            if case let .combo(fid, _, value, _, _) = f, fid == id {
                return value
            }
        }
        return nil
    }

    func firstList(_ id: String) -> [ListItem]? {
        for f in self {
            if case let .list(fid, _, items, _) = f, fid == id {
                return items
            }
        }
        return nil
    }
}

// MARK: - Inference

/// Pick the right editor preset for `node`. `availableIdentifiers`
/// is the list of in-scope `<name>` references the user can pick
/// from — typically the result names produced by earlier
/// statements in the same feature set.
enum NodeEditingSchemaFactory {
    static func infer(
        node: CanvasNode,
        statementSource: String,
        availableIdentifiers: [String]
    ) -> any NodeEditingSchema {
        let verb = node.verb
        let lower = verb.lowercased()
        let result = node.resultName ?? ""
        // Strip a trailing `.` and any `when <expr>` guard so the
        // individual extractors don't pull the guard into their
        // values. The guard is exposed as its own field below.
        let (head, whenExpr) = splitWhen(statementSource)
        // No placeholder: the When clause is optional, and an empty
        // field is the right idle state (per #?). A placeholder
        // reads as a hint that the user "should" enter something,
        // which is the opposite of what unconditional execution
        // means.
        let whenField: EditableField = .expression(
            id: "when",
            label: "When",
            value: whenExpr,
            placeholder: ""
        )
        switch lower {
        case "log":
            return LogEditing(fields: [
                .stringLiteral(id: "message", label: "Message",
                               value: extractLogMessage(from: head),
                               placeholder: "Hello, world"),
                .identifier(id: "target", label: "Target",
                            value: extractLogTarget(from: head)
                                   ?? "console",
                            suggestions: ["console", "stderr"] +
                                         availableIdentifiers),
                whenField,
            ])
        case "create":
            // `Create the <r> with [ … ]` gets the list-row editor
            // so each element is its own input. Falls back to the
            // generic expression field for `{ … }`, primitives, and
            // bindings.
            let valueField: EditableField
            if let items = extractListItems(from: head) {
                valueField = .list(id: "expression",
                                   label: "Items",
                                   items: items,
                                   placeholder: "\"value\" or <binding>")
            } else {
                valueField = .expression(id: "expression",
                                         label: "Value expression",
                                         value: extractWithExpression(from: head),
                                         placeholder: "{ … }")
            }
            return CreateEditing(fields: [
                .identifier(id: "result", label: "Result name",
                            value: result, suggestions: []),
                .combo(id: "modifier", label: "Modifier",
                       value: node.resultModifier ?? "",
                       placeholder: "uppercase, collections.reverse, …",
                       options: QualifierCatalog.snapshot()),
                valueField,
                whenField,
            ])
        case "compute":
            return ComputeEditing(fields: [
                .identifier(id: "result", label: "Result name",
                            value: result, suggestions: []),
                .combo(id: "modifier", label: "Modifier",
                       value: node.resultModifier ?? "",
                       placeholder: "length, uppercase, hash, …",
                       options: QualifierCatalog.snapshot()),
                .expression(id: "expression", label: "Expression",
                            value: extractFromExpression(from: head),
                            placeholder: "5 + 2 * <count>"),
                whenField,
            ])
        case "return":
            return ReturnEditing(fields: [
                .picker(id: "status", label: "Status",
                        value: extractStatus(from: head) ?? "OK",
                        options: ReturnEditing.statusOptions),
                .identifier(id: "subject", label: "Subject",
                            value: node.objectName ?? "result",
                            suggestions: availableIdentifiers),
                whenField,
            ])
        case "emit":
            return EmitEditing(fields: [
                .identifier(id: "event", label: "Event name",
                            value: extractEventName(from: head)
                                   ?? "EventName",
                            suggestions: []),
                .expression(id: "payload", label: "Payload",
                            value: extractWithExpression(from: head),
                            placeholder: "<binding> or { key: value }"),
                whenField,
            ])
        default:
            // Anything that takes a `with { ... }` clause gets the
            // table editor. Otherwise fall through to the generic
            // raw-source editor.
            if statementSource.contains("with") &&
               statementSource.contains("{") {
                // Object slot becomes an editable identifier with
                // a suggestions menu so the user can swap which
                // binding the statement targets (e.g. flip a
                // Store from `<user-repository>` to a backup repo)
                // without rewriting the source. Only added when the
                // original statement actually had an object — verbs
                // without one stay quiet.
                var f: [EditableField] = [
                    .identifier(id: "result", label: "Result name",
                                value: result, suggestions: []),
                ]
                if let objName = node.objectName, !objName.isEmpty,
                   let prep = node.objectPreposition, !prep.isEmpty {
                    f.append(.identifier(
                        id: "object",
                        label: "\(prep.capitalized) the …",
                        value: objName,
                        suggestions: availableIdentifiers
                    ))
                }
                f.append(.record(
                    id: "entries",
                    label: "Fields",
                    rows: extractRecordEntries(from: statementSource)
                ))
                return WithClauseEditing(
                    verb: verb,
                    objectPreposition: node.objectPreposition,
                    objectName: node.objectName,
                    objectModifier: node.objectModifier,
                    fields: f
                )
            }
            return GenericEditing(fields: [
                .expression(id: "raw", label: "Statement",
                            value: statementSource,
                            placeholder: ""),
            ])
        }
    }
}

// MARK: - Source-span surgery

/// Crude extractors that pull substrings out of a statement's
/// source text. Built deliberately tolerant — we'd rather give the
/// user a partly-prefilled editor than refuse to open one because
/// the regex didn't match.
/// Splits a statement's source into `(head, whenExpr)` so the
/// per-field extractors don't have to handle the optional guard
/// themselves. Returns the trimmed head (no trailing `.`) and the
/// raw guard expression (no leading `when`).
private func splitWhen(_ source: String) -> (head: String,
                                              whenExpr: String) {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    let withoutDot = trimmed.hasSuffix(".")
        ? String(trimmed.dropLast())
        : trimmed
    if let match = withoutDot.firstMatch(of: #/(.*?)\s+when\s+(.+)$/#) {
        return (head: String(match.1)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                whenExpr: String(match.2)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return (head: withoutDot, whenExpr: "")
}

private func extractLogMessage(from source: String) -> String {
    if let match = source.firstMatch(of: #/"([^"]*)"/#) {
        return String(match.1)
    }
    return ""
}

private func extractLogTarget(from source: String) -> String? {
    if let match = source.firstMatch(of: #/to the <([^>:]+)(?::[^>]+)?>/#) {
        return String(match.1)
    }
    return nil
}

private func extractWithExpression(from source: String) -> String {
    if let match = source.firstMatch(of: #/with\s+(.+)$/#) {
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

private func extractFromExpression(from source: String) -> String {
    if let match = source.firstMatch(of: #/from\s+(.+)$/#) {
        return String(match.1).trimmingCharacters(in: .whitespaces)
    }
    return ""
}

private func extractStatus(from source: String) -> String? {
    if let match = source.firstMatch(of: #/<([A-Za-z]+):\s*status>/#) {
        return String(match.1)
    }
    return nil
}

private func extractEventName(from source: String) -> String? {
    if let match = source.firstMatch(of: #/<([A-Za-z][A-Za-z0-9]*):\s*event>/#) {
        return String(match.1)
    }
    return nil
}

private func extractRecordEntries(from source: String) -> [RecordRow] {
    // Find the first `{ … }` and pull out top-level `key: value`
    // pairs separated by commas. Bracket-aware so a nested record
    // doesn't get split mid-stream.
    guard let openIdx = source.firstIndex(of: "{") else { return [] }
    var depth = 0
    var endIdx: String.Index? = nil
    for idx in source[openIdx...].indices {
        let ch = source[idx]
        if ch == "{" { depth += 1 }
        if ch == "}" {
            depth -= 1
            if depth == 0 { endIdx = idx; break }
        }
    }
    guard let close = endIdx else { return [] }
    let inner = String(source[source.index(after: openIdx)..<close])
    var rows: [RecordRow] = []
    var current = ""
    var depthLocal = 0
    for ch in inner {
        if ch == "{" || ch == "[" || ch == "(" { depthLocal += 1 }
        if ch == "}" || ch == "]" || ch == ")" { depthLocal -= 1 }
        if ch == "," && depthLocal == 0 {
            if let row = parseRecordPair(current) { rows.append(row) }
            current = ""
        } else {
            current.append(ch)
        }
    }
    if let row = parseRecordPair(current) { rows.append(row) }
    return rows
}

/// Pull the elements of the first top-level `[ … ]` literal in
/// `source`. Returns `nil` when there's no list literal in the
/// statement — the caller falls back to the generic expression
/// field. Element splitting tracks `[`/`{`/`(` depth and respects
/// double-quoted string content so commas inside a string don't
/// fracture an item.
private func extractListItems(from source: String) -> [ListItem]? {
    guard let openIdx = source.firstIndex(of: "[") else { return nil }
    var depth = 0
    var endIdx: String.Index? = nil
    var inString = false
    for idx in source[openIdx...].indices {
        let ch = source[idx]
        if ch == "\"" { inString.toggle(); continue }
        if inString { continue }
        if ch == "[" { depth += 1 }
        if ch == "]" {
            depth -= 1
            if depth == 0 { endIdx = idx; break }
        }
    }
    guard let close = endIdx else { return nil }
    let inner = String(source[source.index(after: openIdx)..<close])
    var items: [ListItem] = []
    var current = ""
    var depthLocal = 0
    var inLocalString = false
    for ch in inner {
        if ch == "\"" {
            inLocalString.toggle()
            current.append(ch)
            continue
        }
        if !inLocalString {
            if ch == "{" || ch == "[" || ch == "(" { depthLocal += 1 }
            if ch == "}" || ch == "]" || ch == ")" { depthLocal -= 1 }
            if ch == "," && depthLocal == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { items.append(ListItem(value: trimmed)) }
                current = ""
                continue
            }
        }
        current.append(ch)
    }
    let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !tail.isEmpty { items.append(ListItem(value: tail)) }
    return items
}

private func parseRecordPair(_ raw: String) -> RecordRow? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let colonIdx = trimmed.firstIndex(of: ":") else { return nil }
    let key = String(trimmed[..<colonIdx])
        .trimmingCharacters(in: .whitespaces)
    let value = String(trimmed[trimmed.index(after: colonIdx)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return RecordRow(key: key, value: value)
}

/// Replace the byte range described by `range` inside `source`
/// with `newText`. Used by the editor's Apply path.
func replacingStatement(
    in source: String,
    byteRange range: Range<Int>,
    with newText: String
) -> String {
    let length = source.utf8.count
    let lo = max(0, min(range.lowerBound, length))
    let hi = max(lo, min(range.upperBound, length))
    let utf8 = source.utf8
    let prefix = String(decoding: utf8.prefix(lo), as: UTF8.self)
    let suffix = String(decoding: utf8.suffix(length - hi), as: UTF8.self)
    return prefix + newText + suffix
}

// MARK: - Editor view

/// Inline editor rendered inside the canvas card when the user
/// double-clicks. Layout is intentionally compact — wider than a
/// normal card to fit the inputs, but not tall enough to bury
/// neighbouring nodes.
struct NodeEditorView: View {
    /// Two-way binding to the schema so each field's input writes
    /// back into its own value.
    @State var schema: any NodeEditingSchema
    let onApply: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Single-line header — no subtitle. Compact title +
            // close button on the trailing edge.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(schema.title)
                    .font(SolaroFont.bodyBold)
                    .foregroundStyle(SolaroColor.textPrimary)
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SolaroColor.textTertiary)
                }
                .buttonStyle(.borderless)
                .help("Cancel and keep the original statement")
            }
            ForEach(schema.fields) { field in
                fieldRow(field)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
                Button("Apply") {
                    if let next = schema.render() { onApply(next) }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(schema.render() == nil)
            }
        }
        .padding(.horizontal, SolaroSpace.s)
        .padding(.vertical, SolaroSpace.xs)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: SolaroRadius.m,
                             style: .continuous)
                .fill(SolaroColor.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SolaroRadius.m,
                             style: .continuous)
                .stroke(SolaroColor.accent.opacity(0.7), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.35), radius: 10, x: 0, y: 4)
    }

    @ViewBuilder
    private func fieldRow(_ field: EditableField) -> some View {
        switch field {
        case let .stringLiteral(id, label, value, placeholder):
            inlineRow(label) {
                TextField(placeholder, text: bindString(id: id, fallback: value))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

        case let .identifier(id, label, value, suggestions):
            inlineRow(label) {
                HStack(spacing: 4) {
                    TextField("<name>",
                              text: bindIdentifier(id: id, fallback: value))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { s in
                                Button(s) { setIdentifier(id: id, to: s) }
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Pick an in-scope variable")
                    }
                }
            }

        case let .expression(id, label, value, placeholder):
            // Single-line by default. Long expressions wrap into
            // the same compact field — the user can paste multi-
            // line content and SwiftUI will scroll inside the
            // text field; keeping the row tall by default would
            // make every editor too big.
            inlineRow(label) {
                TextField(placeholder,
                          text: bindExpression(id: id, fallback: value),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .font(SolaroFont.mono)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

        case let .picker(id, label, value, options):
            inlineRow(label) {
                Picker(label, selection: bindPicker(id: id, fallback: value)) {
                    ForEach(options, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }

        case let .record(id, label, rows):
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(label)
                recordTable(id: id, rows: rows)
            }

        case let .list(id, label, items, placeholder):
            VStack(alignment: .leading, spacing: 4) {
                fieldLabel(label)
                listTable(id: id, items: items, placeholder: placeholder)
            }

        case let .combo(id, label, value, placeholder, options):
            inlineRow(label) {
                HStack(spacing: 4) {
                    TextField(placeholder,
                              text: bindCombo(id: id, fallback: value))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Menu {
                        if !value.isEmpty {
                            Button("Clear modifier") {
                                setCombo(id: id, to: "")
                            }
                            Divider()
                        }
                        ForEach(options) { opt in
                            Button(opt.label) {
                                setCombo(id: id, to: opt.value)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick a registered qualifier")
                }
            }
        }
    }

    @ViewBuilder
    private func inlineRow<Content: View>(
        _ label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            fieldLabel(label)
                .frame(width: 80, alignment: .trailing)
            content()
        }
    }

    @ViewBuilder
    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SolaroFont.sectionTitle)
            .tracking(1)
            .foregroundStyle(SolaroColor.textTertiary)
    }

    @ViewBuilder
    private func listTable(
        id: String,
        items: [ListItem],
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, _ in
                HStack(spacing: 4) {
                    TextField(placeholder,
                              text: bindListItem(fieldID: id, rowIdx: idx))
                        .textFieldStyle(.roundedBorder)
                        .font(SolaroFont.mono)
                        .controlSize(.small)
                    Button {
                        removeListItem(fieldID: id, at: idx)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this item")
                }
            }
            Button {
                appendListItem(fieldID: id)
            } label: {
                Label("Add item", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func recordTable(id: String, rows: [RecordRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                HStack(spacing: 4) {
                    TextField("key",
                              text: bindRecordKey(fieldID: id, rowIdx: idx))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Text(":")
                        .foregroundStyle(SolaroColor.textTertiary)
                    TextField("expression",
                              text: bindRecordValue(fieldID: id, rowIdx: idx))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        removeRow(fieldID: id, at: idx)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                appendRow(fieldID: id)
            } label: {
                Label("Add row", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - State plumbing

    private func bindString(id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { rawString(id) ?? fallback },
            set: { newVal in
                schema.fields = schema.fields.map { f in
                    if case let .stringLiteral(fid, label, _, ph) = f, fid == id {
                        return .stringLiteral(id: fid, label: label,
                                              value: newVal, placeholder: ph)
                    }
                    return f
                }
            }
        )
    }
    private func bindIdentifier(id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { rawIdentifier(id) ?? fallback },
            set: { newVal in
                schema.fields = schema.fields.map { f in
                    if case let .identifier(fid, label, _, sug) = f, fid == id {
                        return .identifier(id: fid, label: label,
                                           value: newVal, suggestions: sug)
                    }
                    return f
                }
            }
        )
    }
    private func setIdentifier(id: String, to newVal: String) {
        bindIdentifier(id: id, fallback: "").wrappedValue = newVal
    }
    private func bindCombo(id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { rawCombo(id) ?? fallback },
            set: { newVal in
                schema.fields = schema.fields.map { f in
                    if case let .combo(fid, label, _, ph, opts) = f, fid == id {
                        return .combo(id: fid, label: label,
                                      value: newVal,
                                      placeholder: ph, options: opts)
                    }
                    return f
                }
            }
        )
    }
    private func setCombo(id: String, to newVal: String) {
        bindCombo(id: id, fallback: "").wrappedValue = newVal
    }
    private func bindExpression(id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { rawExpression(id) ?? fallback },
            set: { newVal in
                schema.fields = schema.fields.map { f in
                    if case let .expression(fid, label, _, ph) = f, fid == id {
                        return .expression(id: fid, label: label,
                                           value: newVal, placeholder: ph)
                    }
                    return f
                }
            }
        )
    }
    private func bindPicker(id: String, fallback: String) -> Binding<String> {
        Binding(
            get: { rawPicker(id) ?? fallback },
            set: { newVal in
                schema.fields = schema.fields.map { f in
                    if case let .picker(fid, label, _, opts) = f, fid == id {
                        return .picker(id: fid, label: label,
                                       value: newVal, options: opts)
                    }
                    return f
                }
            }
        )
    }
    private func bindRecordKey(fieldID: String, rowIdx: Int) -> Binding<String> {
        Binding(
            get: { rawRecord(fieldID)?[rowIdx].key ?? "" },
            set: { newVal in updateRecord(fieldID: fieldID) { rows in
                guard rows.indices.contains(rowIdx) else { return }
                rows[rowIdx].key = newVal
            } }
        )
    }
    private func bindRecordValue(fieldID: String, rowIdx: Int) -> Binding<String> {
        Binding(
            get: { rawRecord(fieldID)?[rowIdx].value ?? "" },
            set: { newVal in updateRecord(fieldID: fieldID) { rows in
                guard rows.indices.contains(rowIdx) else { return }
                rows[rowIdx].value = newVal
            } }
        )
    }
    private func appendRow(fieldID: String) {
        updateRecord(fieldID: fieldID) { $0.append(RecordRow(key: "", value: "")) }
    }
    private func removeRow(fieldID: String, at idx: Int) {
        updateRecord(fieldID: fieldID) { rows in
            guard rows.indices.contains(idx) else { return }
            rows.remove(at: idx)
        }
    }

    private func rawString(_ id: String) -> String? {
        for f in schema.fields {
            if case let .stringLiteral(fid, _, v, _) = f, fid == id { return v }
        }
        return nil
    }
    private func rawIdentifier(_ id: String) -> String? {
        for f in schema.fields {
            if case let .identifier(fid, _, v, _) = f, fid == id { return v }
        }
        return nil
    }
    private func rawExpression(_ id: String) -> String? {
        for f in schema.fields {
            if case let .expression(fid, _, v, _) = f, fid == id { return v }
        }
        return nil
    }
    private func rawPicker(_ id: String) -> String? {
        for f in schema.fields {
            if case let .picker(fid, _, v, _) = f, fid == id { return v }
        }
        return nil
    }
    private func bindListItem(fieldID: String, rowIdx: Int) -> Binding<String> {
        Binding(
            get: { rawList(fieldID)?[rowIdx].value ?? "" },
            set: { newVal in updateList(fieldID: fieldID) { items in
                guard items.indices.contains(rowIdx) else { return }
                items[rowIdx].value = newVal
            } }
        )
    }
    private func appendListItem(fieldID: String) {
        updateList(fieldID: fieldID) { $0.append(ListItem(value: "")) }
    }
    private func removeListItem(fieldID: String, at idx: Int) {
        updateList(fieldID: fieldID) { items in
            guard items.indices.contains(idx) else { return }
            items.remove(at: idx)
        }
    }
    private func rawList(_ id: String) -> [ListItem]? {
        for f in schema.fields {
            if case let .list(fid, _, items, _) = f, fid == id { return items }
        }
        return nil
    }
    private func updateList(fieldID: String, _ mutate: (inout [ListItem]) -> Void) {
        schema.fields = schema.fields.map { f in
            if case let .list(fid, label, items, placeholder) = f, fid == fieldID {
                var copy = items
                mutate(&copy)
                return .list(id: fid, label: label, items: copy, placeholder: placeholder)
            }
            return f
        }
    }

    private func rawRecord(_ id: String) -> [RecordRow]? {
        for f in schema.fields {
            if case let .record(fid, _, rows) = f, fid == id { return rows }
        }
        return nil
    }
    private func rawCombo(_ id: String) -> String? {
        for f in schema.fields {
            if case let .combo(fid, _, v, _, _) = f, fid == id { return v }
        }
        return nil
    }
    private func updateRecord(fieldID: String, _ mutate: (inout [RecordRow]) -> Void) {
        schema.fields = schema.fields.map { f in
            if case let .record(fid, label, rows) = f, fid == fieldID {
                var copy = rows
                mutate(&copy)
                return .record(id: fid, label: label, rows: copy)
            }
            return f
        }
    }
}
