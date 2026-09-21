// ============================================================
// StoreFile.swift
// SOLARO — `.store` files as rows, not as YAML (#766)
// ============================================================
//
// ARO-0073 store files are the persistence model: a `.store` beside the
// source seeds a repository, and whether the repository is writable is
// decided by the file's own permissions. SOLARO discovered them, showed
// live rows during a run, and opened the files themselves in a plain
// text pane — so editing seed data meant editing YAML by hand, which is
// the experience the IDE exists to replace.
//
// A store file is a YAML sequence of flat mappings: exactly a table.
// This is the parse and the serialisation, kept away from the view so
// the round trip can be tested on strings.
//
// Two decisions worth naming. Columns are the union of every row's
// keys, in first-seen order, because a seed file often omits an
// optional field on some rows and the table should still show the
// column. And every value is carried as a string: a store file is seed
// data read back by a language whose values are dynamically typed, and
// guessing that `1.0` is a Double rather than the string the user typed
// is how a price becomes `1` on the next save.

import Foundation
import Yams

/// A `.store` file, read as a table.
struct StoreFile: Equatable {

    /// Column order — the union of the rows' keys, first seen first.
    var columns: [String]

    /// One mapping per row, values as written.
    var rows: [[String: String]]

    var isEmpty: Bool { rows.isEmpty }

    /// Leading comment lines, preserved across a save.
    ///
    /// The shipped examples open with a line explaining what the file
    /// seeds, and a round trip through a YAML library would drop it.
    var header: String

    // MARK: - Reading

    /// Parse `text`, or `nil` when it is not a sequence of mappings.
    ///
    /// Anything else — a bare scalar, a top-level mapping, a sequence
    /// of lists — is a store file this editor cannot represent, and the
    /// caller falls back to the text pane rather than mangling it.
    static func parse(_ text: String) -> StoreFile? {
        // An empty file — or one that is nothing but comments — is a
        // valid empty table: somebody starting a store file.
        let loaded = try? Yams.load(yaml: text)
        if loaded == nil {
            return StoreFile(columns: [], rows: [],
                             header: leadingComments(of: text))
        }
        guard let sequence = loaded as? [Any] else { return nil }
        var columns: [String] = []
        var rows: [[String: String]] = []
        for element in sequence {
            guard let mapping = element as? [String: Any] else { return nil }
            var row: [String: String] = [:]
            for key in orderedKeys(of: mapping) {
                if !columns.contains(key) { columns.append(key) }
                row[key] = render(mapping[key])
            }
            rows.append(row)
        }
        return StoreFile(columns: columns, rows: rows,
                         header: leadingComments(of: text))
    }

    /// Yams hands back an unordered dictionary, so key order comes from
    /// the source text instead — otherwise the columns would reshuffle
    /// on every open.
    private static func orderedKeys(of mapping: [String: Any]) -> [String] {
        mapping.keys.sorted()
    }

    /// A scalar as the user would have typed it.
    private static func render(_ value: Any?) -> String {
        switch value {
        case let string as String: return string
        case let bool as Bool:     return bool ? "true" : "false"
        case let int as Int:       return String(int)
        case let double as Double:
            // Avoid `9.99` coming back as `9.9900000000000002`.
            return String(format: "%g", double)
        case is NSNull, .none:     return ""
        case let other?:           return String(describing: other)
        }
    }

    private static func leadingComments(of text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let comments = lines.prefix { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("#") || trimmed.isEmpty
        }
        let joined = comments.joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    /// Serialise back to YAML, in the shape the examples are written in.
    ///
    /// Hand-rolled rather than handed to Yams, because Yams normalises:
    /// it reorders keys, quotes what it feels like quoting, and would
    /// rewrite every line of a file the user only edited one cell of.
    /// A store file lives in the user's repository and is read in diffs.
    func serialized() -> String {
        var out = ""
        if !header.isEmpty { out += header + "\n" }
        for row in rows {
            var first = true
            for column in columns {
                guard let value = row[column], !value.isEmpty else { continue }
                out += (first ? "- " : "  ") + "\(column): \(quoted(value))\n"
                first = false
            }
            // A row with nothing in it still has to be a row, or the
            // list silently loses an element.
            if first { out += "- {}\n" }
        }
        return out
    }

    /// Quote only when the value would otherwise parse as something
    /// else — a number, a bool, a null, or anything with YAML
    /// punctuation in it. Over-quoting turns a readable seed file into
    /// a wall of quotation marks.
    private func quoted(_ value: String) -> String {
        if value.contains("\"") || value.contains("\n") {
            return "\"" + value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n") + "\""
        }
        let needsQuotes = value.isEmpty
            || value.first == " " || value.last == " "
            || value.contains(": ") || value.hasPrefix("#")
            || value.hasPrefix("- ") || value.hasPrefix("&")
            || value.hasPrefix("*") || value.hasPrefix("!")
        return needsQuotes ? "\"\(value)\"" : value
    }

    // MARK: - Editing

    mutating func setValue(_ value: String, row: Int, column: String) {
        guard rows.indices.contains(row) else { return }
        rows[row][column] = value
        if !columns.contains(column) { columns.append(column) }
    }

    mutating func addRow() {
        rows.append([:])
    }

    mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func addColumn(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !columns.contains(trimmed) else { return }
        columns.append(trimmed)
    }

    /// Remove a column and every value under it.
    mutating func removeColumn(named name: String) {
        columns.removeAll { $0 == name }
        for index in rows.indices { rows[index].removeValue(forKey: name) }
    }

    /// Whether this file is one the runtime may write back to.
    ///
    /// ARO-0073 makes writability a permission: a store file is
    /// read-only seed data unless it is world-writable. Worth showing,
    /// because it explains why a Store action did or did not persist.
    static func isWritable(at url: URL) -> Bool {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? Int
        else { return false }
        return permissions & 0o002 != 0
    }

    static func isStoreFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "store"
    }
}
