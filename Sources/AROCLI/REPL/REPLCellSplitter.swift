// ============================================================
// REPLCellSplitter.swift
// ARO REPL — splitting a notebook cell into executable units
// ============================================================
//
// A terminal REPL reads one input at a time, so `REPLShell` can decide what
// an input is as the user types it. A notebook cell arrives whole and may
// mix kinds: a feature-set definition, then statements that use it, then a
// meta-command. This splits such a cell the way the shell would have, using
// the same `MultilineDetector` that decides when interactive input is done.
//
// Consecutive statements are deliberately kept together as one unit rather
// than run one-by-one: `REPLSession.executeStatement` wraps its input in a
// single feature set, and statements in one feature set can overlap their
// I/O (ARO-0088). Splitting them would serialise work the language is
// explicitly allowed to run concurrently.

import Foundation

/// One executable piece of a cell.
enum REPLCellUnit: Sendable {
    /// A `:`-prefixed meta-command line (`:vars`, `:fs`, …).
    case meta(String, startLine: Int)
    /// A complete `(Name: Activity) { … }` definition.
    case featureSet(name: String, activity: String, source: String, startLine: Int)
    /// One or more statements, to be executed as a single feature set body.
    case statements(String, startLine: Int)

    /// 0-based line within the cell where this unit starts. Used to map
    /// diagnostics back onto the cell the user is looking at.
    var startLine: Int {
        switch self {
        case .meta(_, let line), .featureSet(_, _, _, let line), .statements(_, let line):
            return line
        }
    }
}

enum REPLCellSplitter {
    /// Split `cell` into units in source order.
    ///
    /// Returns an empty array for a blank cell. Unterminated input (an
    /// unclosed brace at end of cell) is returned as its own unit anyway —
    /// the compiler produces a better message about it than this splitter
    /// could, and `is_complete` is what stops such a cell being submitted in
    /// the first place.
    static func split(_ cell: String) -> [REPLCellUnit] {
        let lines = cell.components(separatedBy: .newlines)
        var units: [REPLCellUnit] = []

        var buffer: [String] = []
        var bufferStart = 0
        var bufferIsFeatureSet = false
        var featureSetHeader: (name: String, activity: String)?

        func flushStatements() {
            defer { buffer.removeAll() }
            let source = buffer.joined(separator: "\n")
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            units.append(.statements(source, startLine: bufferStart))
        }

        func flushFeatureSet() {
            defer {
                buffer.removeAll()
                bufferIsFeatureSet = false
                featureSetHeader = nil
            }
            let source = buffer.joined(separator: "\n")
            guard let header = featureSetHeader else {
                units.append(.statements(source, startLine: bufferStart))
                return
            }
            units.append(.featureSet(
                name: header.name,
                activity: header.activity,
                source: source,
                startLine: bufferStart
            ))
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if buffer.isEmpty {
                if trimmed.isEmpty { continue }

                // A meta-command is always exactly one line.
                if trimmed.hasPrefix(":") {
                    units.append(.meta(trimmed, startLine: index))
                    continue
                }

                bufferStart = index
                if MultilineDetector.isFeatureSetStart(trimmed) {
                    bufferIsFeatureSet = true
                    featureSetHeader = MultilineDetector.parseFeatureSetHeader(trimmed)
                }
                buffer.append(line)
            } else if bufferIsFeatureSet {
                buffer.append(line)
            } else {
                // A statement chunk ends where a definition or meta-command
                // begins — but only when what we have so far is balanced,
                // otherwise we are still inside a multi-line statement.
                let balanced = isComplete(buffer.joined(separator: "\n"))
                if balanced && (trimmed.hasPrefix(":") || MultilineDetector.isFeatureSetStart(trimmed)) {
                    flushStatements()
                    if trimmed.hasPrefix(":") {
                        units.append(.meta(trimmed, startLine: index))
                    } else {
                        bufferStart = index
                        bufferIsFeatureSet = true
                        featureSetHeader = MultilineDetector.parseFeatureSetHeader(trimmed)
                        buffer.append(line)
                    }
                    continue
                }
                buffer.append(line)
            }

            // A definition is done as soon as its braces balance.
            if bufferIsFeatureSet && isComplete(buffer.joined(separator: "\n")) {
                flushFeatureSet()
            }
        }

        if !buffer.isEmpty {
            if bufferIsFeatureSet {
                flushFeatureSet()
            } else {
                flushStatements()
            }
        }

        return units
    }

    /// Whether `source` is syntactically closed (all braces, parens,
    /// brackets and strings terminated).
    static func isComplete(_ source: String) -> Bool {
        if case .complete = MultilineDetector.check(source) { return true }
        return false
    }
}
