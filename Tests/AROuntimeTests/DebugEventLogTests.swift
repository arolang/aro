// ============================================================
// DebugEventLogTests.swift
// ARO Runtime - JSONL record/replay round-trip (Issue #229 Phase 4)
// ============================================================

import XCTest
@testable import ARORuntime

final class DebugEventLogTests: XCTestCase {

    func testRoundTripWriteRead() async throws {
        let tmp = NSTemporaryDirectory() + "/aro-debug-test-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let writer = try DebugEventLogWriter(path: tmp)
        await writer.write(.pause, body: [
            "fs": "createUser",
            "line": "5",
            "stmt": "Create the <user> with <data>."
        ])
        await writer.write(.event, body: [
            "name": "UserCreated",
            "payload": "{id:530}"
        ])
        await writer.write(.end, body: [:])
        await writer.close()

        let reader = try DebugEventLogReader(path: tmp)
        XCTAssertEqual(reader.records.count, 3)
        XCTAssertEqual(reader.records[0].kind, .pause)
        XCTAssertEqual(reader.records[0].body["fs"], "createUser")
        XCTAssertEqual(reader.records[1].kind, .event)
        XCTAssertEqual(reader.records[1].body["name"], "UserCreated")
        XCTAssertEqual(reader.records[2].kind, .end)
        // Times must monotonically increase
        XCTAssertLessThanOrEqual(reader.records[0].time, reader.records[1].time)
    }

    func testDecodeIgnoresMalformedLines() {
        let line = "not json"
        XCTAssertNil(DebugEventRecord.decodeJSONLine(line))
    }
}
