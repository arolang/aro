// ============================================================
// DebugEventLog.swift
// ARO Runtime - Time-travel JSONL log (Issue #229 Phase 4)
// ============================================================
//
// One file format serves three jobs:
//   1. `aro debug --record session.jsonl`  → writes
//   2. `aro debug --replay session.jsonl`  → reads and re-pauses
//   3. SOLARO time-travel scrubber (issue #228, figure 11) consumes the
//      same stream live or after-the-fact.
//
// Each line is a single self-describing JSON object so the file is
// streamable, tail-able, diffable, and trivial to fan out to multiple
// readers without buffering the full session in memory.
//
// Wire schema (intentionally tiny; additive fields are fine):
//
//   {"t": 12.4, "k": "pause", "reason": "step|breakpoint|entry|event|error",
//    "fs": "createUser", "act": "User API",
//    "file": "users.aro", "line": 5, "col": 9,
//    "verb": "Create", "stmt": "Create the <user> with <data>.",
//    "syms": [{"n": "user", "ty": "User", "v": "{name:Ada,…}"}]}
//
//   {"t": 12.5, "k": "event", "name": "UserCreated", "payload": "{id:530}"}
//
//   {"t": 12.6, "k": "error", "msg": "Validation failed: email missing"}
//
// `t` is wall-clock seconds since the recording started (Double); SOLARO
// uses it for the cursor timeline. `k` is a one-letter discriminator.

import Foundation

public struct DebugEventRecord: Sendable {
    public enum Kind: String, Sendable { case pause, event, error, end }

    public let time: Double
    public let kind: Kind
    public let body: [String: String]   // flat string values; structured payloads pre-rendered

    public init(time: Double, kind: Kind, body: [String: String]) {
        self.time = time
        self.kind = kind
        self.body = body
    }

    public func encodeJSONLine() -> Data {
        var obj: [String: Any] = ["t": time, "k": kind.rawValue]
        for (k, v) in body { obj[k] = v }
        let json = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        var out = json
        out.append(0x0A) // newline
        return out
    }

    public static func decodeJSONLine(_ line: String) -> DebugEventRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? Double,
              let kStr = obj["k"] as? String,
              let kind = Kind(rawValue: kStr)
        else { return nil }
        var body: [String: String] = [:]
        for (k, v) in obj where k != "t" && k != "k" {
            if let s = v as? String { body[k] = s }
            else if let n = v as? NSNumber { body[k] = n.stringValue }
            else { body[k] = String(describing: v) }
        }
        return DebugEventRecord(time: t, kind: kind, body: body)
    }
}

/// Append-only JSONL writer. Safe to call from any actor — wraps a
/// FileHandle in a synchronizing actor.
public actor DebugEventLogWriter {
    private let handle: FileHandle
    private let startedAt: Date

    public init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else {
            throw NSError(domain: "DebugEventLogWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot open \(path) for writing"])
        }
        self.handle = h
        self.startedAt = Date()
    }

    public func write(_ kind: DebugEventRecord.Kind, body: [String: String]) {
        let t = Date().timeIntervalSince(startedAt)
        let record = DebugEventRecord(time: t, kind: kind, body: body)
        try? handle.write(contentsOf: record.encodeJSONLine())
    }

    public func close() {
        try? handle.close()
    }
}

/// JSONL replay reader. Loads the full file into memory (a session of a
/// few thousand events is hundreds of KB at most). The caller drives
/// playback by stepping the cursor — Phase 4 keeps this single-cursor
/// rather than building the full fork-and-replay tree out of the gate.
public struct DebugEventLogReader: Sendable {
    public let records: [DebugEventRecord]

    public init(path: String) throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        self.records = text.split(separator: "\n").compactMap {
            DebugEventRecord.decodeJSONLine(String($0))
        }
    }
}
