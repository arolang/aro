// ============================================================
// LiveValueIndex.swift
// SOLARO — feed canvas hover popovers with values from a
//          recorded run (#233 §2)
// ============================================================
//
// After `aro debug --record` (or `aro run` when SOLARO injects
// recording flags) finishes, `.solaro/events.jsonl` holds the
// per-statement symbol snapshots produced during execution. We
// load the file, walk every record, and build the *latest* value
// seen for each binding name. That dict is then merged into the
// workspace's `pauseSymbols`, so the existing canvas node hover
// popover automatically shows live runtime values — no separate
// rendering path.

import Foundation

/// Pure I/O — no actor isolation needed.
enum LiveValueIndex {
    /// Walk every record in `.solaro/events.jsonl` and return the
    /// last value seen per binding name. Records without symbol
    /// snapshots are skipped. If the file is missing the returned
    /// dictionary is empty (the workspace falls back to whatever
    /// the debugger had).
    static func load(for project: Project) -> [String: ConsoleProcess.SymbolValue] {
        let url = project.rootPath
            .appendingPathComponent(".solaro", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard
            let records = try? TimeTravelReader.load(from: url),
            !records.isEmpty
        else { return [:] }

        var latest: [String: ConsoleProcess.SymbolValue] = [:]
        for record in records {
            for symbol in record.symbols {
                latest[symbol.name] = ConsoleProcess.SymbolValue(
                    name: symbol.name,
                    typeName: symbol.typeName,
                    value: symbol.value
                )
            }
        }
        return latest
    }
}
