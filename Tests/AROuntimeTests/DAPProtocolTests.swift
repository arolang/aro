// ============================================================
// DAPProtocolTests.swift
// ARO Runtime - DAP message encode/decode round-trips (Issue #229 Phase 2)
// ============================================================

import XCTest
@testable import ARORuntime

final class DAPProtocolTests: XCTestCase {

    func testEncodeRequestRoundTrip() throws {
        let req = DAPMessage(
            seq: 1, kind: .request, name: "setBreakpoints",
            arguments: [
                "source": ["name": "users.aro"],
                "breakpoints": [["line": 5], ["line": 7]]
            ]
        )
        let encoded = try req.encode()
        let split = try splitFrame(encoded)
        let decoded = try DAPMessage.decode(split.body)
        XCTAssertEqual(decoded.kind, .request)
        XCTAssertEqual(decoded.name, "setBreakpoints")
        XCTAssertEqual(decoded.seq, 1)
        XCTAssertNotNil(decoded.arguments?["breakpoints"])
    }

    func testEncodeEventRoundTrip() throws {
        let evt = DAPMessage(
            seq: 42, kind: .event, name: "stopped",
            body: ["reason": "breakpoint", "threadId": 1]
        )
        let encoded = try evt.encode()
        let split = try splitFrame(encoded)
        let decoded = try DAPMessage.decode(split.body)
        XCTAssertEqual(decoded.kind, .event)
        XCTAssertEqual(decoded.name, "stopped")
        XCTAssertEqual(decoded.body?["reason"] as? String, "breakpoint")
    }

    func testReaderHandlesChunkedFraming() async throws {
        // Build two framed messages back-to-back and feed them through a
        // pipe a few bytes at a time. The reader must reassemble.
        let pipe = Pipe()
        let reader = DAPReader(handle: pipe.fileHandleForReading)

        let m1 = try DAPMessage(seq: 1, kind: .request, name: "initialize").encode()
        let m2 = try DAPMessage(seq: 2, kind: .request, name: "launch").encode()
        let full = m1 + m2

        // Write in small chunks from a background task.
        Task {
            for byte in full {
                try? pipe.fileHandleForWriting.write(contentsOf: [byte])
            }
            try? pipe.fileHandleForWriting.close()
        }

        let first = try await reader.read()
        let second = try await reader.read()
        XCTAssertEqual(first?.name, "initialize")
        XCTAssertEqual(second?.name, "launch")
    }

    // MARK: - Helpers

    private func splitFrame(_ data: Data) throws -> (header: String, body: Data) {
        let sep = data.range(of: Data("\r\n\r\n".utf8))!
        let header = String(data: data.subdata(in: 0..<sep.lowerBound), encoding: .utf8) ?? ""
        let body = data.subdata(in: sep.upperBound..<data.count)
        return (header, body)
    }
}
