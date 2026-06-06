// ============================================================
// TimeTravelReader.swift
// SOLARO — JSONL replay reader (Phase 3, consumes #229 format)
// ============================================================
//
// Reads the JSONL debug event log produced by `aro debug --record`
// (issue #229 Phase 4) and exposes the events as a scrubbable
// timeline for SOLARO's time-travel view (wireframe note 8467
// figure 11).

import Foundation

/// One record from the JSONL stream. Kept intentionally schema-light:
/// the debugger may add new optional fields and SOLARO must keep
/// working.
struct TimeTravelRecord: Equatable {
    let time: Double            // seconds since session start
    let kind: Kind
    let featureSet: String?
    let file: String?
    let line: Int?
    let column: Int?
    let statement: String?
    let verb: String?
    let reason: String?
    let symbols: [Symbol]
    /// Per-checkpoint timing + memory (#282 phase 2). Optional
    /// because older JSONL recordings and the subprocess path
    /// don't include them; views render the metrics row only
    /// when present.
    let metrics: Metrics?

    init(time: Double, kind: Kind,
         featureSet: String?, file: String?, line: Int?, column: Int?,
         statement: String?, verb: String?, reason: String?,
         symbols: [Symbol], metrics: Metrics? = nil) {
        self.time = time
        self.kind = kind
        self.featureSet = featureSet
        self.file = file
        self.line = line
        self.column = column
        self.statement = statement
        self.verb = verb
        self.reason = reason
        self.symbols = symbols
        self.metrics = metrics
    }

    enum Kind: String {
        case pause
        case event
        case error
        case end
    }

    struct Symbol: Equatable {
        let name: String
        let typeName: String
        let value: String
    }

    struct Metrics: Equatable {
        /// Wall-clock nanoseconds between this checkpoint and
        /// the previous one in the same execution.
        let elapsedNanos: UInt64
        /// RSS of the runtime process at the moment of the
        /// checkpoint, in bytes. Zero when the platform refused
        /// to answer.
        let residentMemoryBytes: UInt64
    }
}

enum TimeTravelReader {

    /// Parse a JSONL file. Returns the records in the order they
    /// appear in the file. Lines that don't parse are silently
    /// skipped (matches the `aro debug --replay` behavior in #229).
    static func load(from url: URL) throws -> [TimeTravelRecord] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text)
    }

    /// Test-friendly entry point that takes a string directly.
    static func parse(_ text: String) -> [TimeTravelRecord] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { decode(String($0)) }
    }

    private static func decode(_ line: String) -> TimeTravelRecord? {
        guard
            let data = line.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = obj["t"] as? Double,
            let kStr = obj["k"] as? String,
            let kind = TimeTravelRecord.Kind(rawValue: kStr)
        else { return nil }

        // The debugger renders line/col as strings inside the
        // JSONL records (see #229 Phase 4 schema in DebugEventLog.swift)
        // so we coerce both string and numeric forms.
        let line = asInt(obj["line"])
        let col = asInt(obj["col"])

        var symbols: [TimeTravelRecord.Symbol] = []
        if let symsJSON = obj["syms"] as? String,
           let symsData = symsJSON.data(using: .utf8),
           let symsArr = try? JSONSerialization.jsonObject(with: symsData) as? [[String: String]] {
            for entry in symsArr {
                symbols.append(.init(
                    name: entry["n"] ?? "",
                    typeName: entry["ty"] ?? "?",
                    value: entry["v"] ?? ""
                ))
            }
        }

        return TimeTravelRecord(
            time: t,
            kind: kind,
            featureSet: obj["fs"] as? String,
            file: obj["file"] as? String,
            line: line,
            column: col,
            statement: obj["stmt"] as? String,
            verb: obj["verb"] as? String,
            reason: obj["reason"] as? String,
            symbols: symbols
        )
    }

    private static func asInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
