// ============================================================
// OpenAPISourceMap.swift
// SOLARO — locate route/schema declarations in openapi.yaml
// ============================================================
//
// Yams round-trips through a dictionary that doesn't preserve
// source line numbers, so we rebuild the mapping with a small
// textual scan. Good enough for the IDE's double-click-to-jump:
// every route's `<method>:` and every schema's `<name>:` is
// found with a couple of indent-aware passes over the YAML.

import Foundation

enum OpenAPISourceMap {
    /// Returns the 1-based line number for the given node id, or
    /// `nil` if we can't locate it. Node ids follow OpenAPIGraph's
    /// conventions: `route:GET /users`, `schema:User`.
    static func line(for nodeID: String, in yaml: String) -> Int? {
        let lines = yaml.components(separatedBy: "\n")
        if let route = parseRouteID(nodeID) {
            return findRouteLine(
                lines: lines,
                method: route.method,
                path: route.path
            )
        }
        if nodeID.hasPrefix("schema:") {
            let name = String(nodeID.dropFirst("schema:".count))
            return findSchemaLine(lines: lines, name: name)
        }
        return nil
    }

    // MARK: - Routes

    private struct RouteID {
        let method: String
        let path: String
    }

    private static func parseRouteID(_ id: String) -> RouteID? {
        guard id.hasPrefix("route:") else { return nil }
        let rest = id.dropFirst("route:".count)
        let parts = rest.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return RouteID(
            method: String(parts[0]).lowercased(),
            path: String(parts[1])
        )
    }

    /// Walks the YAML looking for the `paths:` block, then for the
    /// matching `<path>:` key, then for the requested method key.
    /// Returns the method's line; falls back to the path's line if
    /// the method is absent (e.g. route only has a description).
    private static func findRouteLine(
        lines: [String],
        method: String,
        path: String
    ) -> Int? {
        guard let pathsLine = topLevelKeyLine(lines: lines, key: "paths") else {
            return nil
        }
        guard
            let pathLine = nestedKeyLine(
                lines: lines,
                parentLine: pathsLine,
                key: path
            )
        else {
            return nil
        }
        if let methodLine = nestedKeyLine(
            lines: lines,
            parentLine: pathLine,
            key: method
        ) {
            return methodLine + 1
        }
        return pathLine + 1
    }

    // MARK: - Schemas

    /// Look up `components.schemas.<name>:`. Falls through to the
    /// `definitions` key for Swagger 2.0 files.
    private static func findSchemaLine(
        lines: [String],
        name: String
    ) -> Int? {
        if let line = locateUnderTwoLevels(
            lines: lines,
            top: "components",
            mid: "schemas",
            leaf: name
        ) {
            return line + 1
        }
        if let definitionsLine = topLevelKeyLine(lines: lines, key: "definitions"),
           let leaf = nestedKeyLine(
             lines: lines,
             parentLine: definitionsLine,
             key: name
           )
        {
            return leaf + 1
        }
        return nil
    }

    private static func locateUnderTwoLevels(
        lines: [String],
        top: String,
        mid: String,
        leaf: String
    ) -> Int? {
        guard let topLine = topLevelKeyLine(lines: lines, key: top),
              let midLine = nestedKeyLine(
                  lines: lines, parentLine: topLine, key: mid
              )
        else { return nil }
        return nestedKeyLine(lines: lines, parentLine: midLine, key: leaf)
    }

    // MARK: - YAML walk

    /// Find a 0-indented `<key>:` line. Comments and blank lines
    /// are skipped naturally because we look for an exact prefix.
    private static func topLevelKeyLine(lines: [String], key: String) -> Int? {
        let needle = "\(key):"
        for (i, line) in lines.enumerated() where line.hasPrefix(needle) {
            return i
        }
        return nil
    }

    /// Find a child key indented strictly deeper than the parent.
    /// We anchor on the indent of the first non-blank line under
    /// the parent — that's the canonical "one level deeper" — and
    /// match `<key>:` only at exactly that depth, so we don't
    /// accidentally pick up grandchildren or unrelated siblings.
    private static func nestedKeyLine(
        lines: [String],
        parentLine: Int,
        key: String
    ) -> Int? {
        let parentIndent = indent(of: lines[parentLine])
        var childIndent: Int? = nil
        for i in (parentLine + 1)..<lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let here = indent(of: line)
            if here <= parentIndent { return nil }
            if childIndent == nil { childIndent = here }
            guard here == childIndent else { continue }
            if matchesKey(line: line, key: key) {
                return i
            }
        }
        return nil
    }

    private static func matchesKey(line: String, key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // The key may be plain (`User:`), quoted (`"/users":`), or
        // single-quoted (`'/users':`). Strip surrounding quotes
        // before comparing so paths with slashes line up too.
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        var name = String(trimmed[..<colon])
        if (name.first == "\"" && name.last == "\"") ||
           (name.first == "'"  && name.last == "'") {
            name = String(name.dropFirst().dropLast())
        }
        return name == key
    }

    private static func indent(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 4 }
            else { break }
        }
        return count
    }
}
