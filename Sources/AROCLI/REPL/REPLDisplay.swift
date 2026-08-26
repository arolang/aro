// ============================================================
// REPLDisplay.swift
// ARO REPL — rendering a value into a MIME bundle
// ============================================================
//
// Jupyter shows whichever representation the front-end prefers, so a value
// is offered in several at once: plain text always, JSON when it encodes,
// and an HTML table when the value is tabular. Notebooks are where ARO's
// collection actions (ARO-0018) are most worth looking at, and a list of
// records is unreadable as one long line of text.
//
// Text comes from `ResponseFormatter` in `.human` — the same renderer the
// runtime uses for console output — rather than from `REPLShell.formatValue`,
// which interleaves ANSI colour that a notebook would render as mojibake.

import Foundation
import ARORuntime

enum REPLDisplay {

    /// Build the MIME bundle for `value`.
    ///
    /// `text/plain` is always present; the others appear only when they
    /// apply, so a front-end never receives an empty or misleading richer
    /// representation to prefer over the text.
    static func bundle(for value: any Sendable) -> [String: Any] {
        var bundle: [String: Any] = [
            "text/plain": ResponseFormatter.formatValue(value, for: .human)
        ]

        let unwrapped = unwrap(value)
        if JSONSerialization.isValidJSONObject(unwrapped) || isJSONScalar(unwrapped) {
            bundle["application/json"] = unwrapped
        }
        if let html = htmlTable(for: unwrapped) {
            bundle["text/html"] = html
        }
        return bundle
    }

    // MARK: - Unwrapping

    /// Convert a runtime value into JSON-representable form.
    ///
    /// `AnySendable` boxes are opened by probing the types the runtime
    /// actually stores; anything else degrades to its description rather
    /// than being dropped, because a value the user can see beats a value
    /// silently missing from the cell.
    static func unwrap(_ value: any Sendable) -> Any {
        if let boxed = value as? AnySendable {
            if let v: String = boxed.get() { return v }
            if let v: Int = boxed.get() { return v }
            if let v: Double = boxed.get() { return v }
            if let v: Bool = boxed.get() { return v }
            if let v: [String: any Sendable] = boxed.get() { return unwrap(v) }
            if let v: [any Sendable] = boxed.get() { return unwrap(v) }
            if let v: [String] = boxed.get() { return v }
            return String(describing: boxed)
        }

        switch value {
        case let v as String: return v
        case let v as Int: return v
        case let v as Double: return v.isFinite ? v : String(describing: v)
        case let v as Bool: return v
        case let v as [String: any Sendable]: return v.mapValues { unwrap($0) }
        case let v as [any Sendable]: return v.map { unwrap($0) }
        default: return String(describing: value)
        }
    }

    private static func isJSONScalar(_ value: Any) -> Bool {
        value is String || value is Int || value is Double || value is Bool
    }

    // MARK: - HTML

    /// An HTML table for tabular values, `nil` for everything else.
    ///
    /// Two shapes qualify: a list of records (one row each, union of keys as
    /// columns) and a single record (key/value rows). A list of scalars is
    /// left to `text/plain` — a one-column table is noise.
    private static func htmlTable(for value: Any) -> String? {
        if let rows = value as? [Any] {
            let records = rows.compactMap { $0 as? [String: Any] }
            guard !records.isEmpty, records.count == rows.count else { return nil }

            // Column order: first appearance across the rows, so the table
            // reads in the order the data was built, not alphabetically.
            var columns: [String] = []
            for record in records {
                for key in record.keys.sorted() where !columns.contains(key) {
                    columns.append(key)
                }
            }

            let header = columns.map { "<th>\(escape($0))</th>" }.joined()
            let body = records.map { record in
                let cells = columns.map { "<td>\(escape(cell(record[$0])))</td>" }.joined()
                return "<tr>\(cells)</tr>"
            }.joined()
            return table("<thead><tr>\(header)</tr></thead><tbody>\(body)</tbody>")
        }

        if let record = value as? [String: Any], !record.isEmpty {
            let rows = record.keys.sorted().map { key in
                "<tr><th style=\"text-align:left\">\(escape(key))</th><td>\(escape(cell(record[key])))</td></tr>"
            }.joined()
            return table("<tbody>\(rows)</tbody>")
        }

        return nil
    }

    private static func table(_ inner: String) -> String {
        // Inline styles only: a notebook's CSS is not ours to extend, and
        // nbconvert output has no stylesheet at all.
        "<table style=\"border-collapse:collapse\" class=\"aro-table\">\(inner)</table>"
    }

    private static func cell(_ value: Any?) -> String {
        guard let value else { return "" }
        if let string = value as? String { return string }
        if let nested = value as? [Any] {
            return nested.map { cell($0) }.joined(separator: ", ")
        }
        if let nested = value as? [String: Any] {
            return nested.keys.sorted().map { "\($0): \(cell(nested[$0]))" }.joined(separator: ", ")
        }
        return String(describing: value)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
