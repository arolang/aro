// ============================================================
// DAPProtocol.swift
// ARO Runtime - Debug Adapter Protocol — minimal message types
// ============================================================
//
// Issue #229 Phase 2. Just the wire encoding plus the small subset of
// DAP messages SOLARO / VS Code / nvim-dap actually call on us:
//   requests:  initialize, launch, configurationDone, setBreakpoints,
//              setExceptionBreakpoints, threads, stackTrace, scopes,
//              variables, continue, next, stepIn, stepOut, pause,
//              disconnect, terminate
//   events:    initialized, stopped, terminated, output, exited
//
// All bodies are encoded as plain `[String: Any]` dictionaries serialized
// through JSONSerialization. This avoids hand-rolling a Codable type per
// DAP message — there are ~50 of them and we only handle ~15 — but the
// concrete request/response shape is documented in `DAPMessage`.

import Foundation

/// Top-level DAP message shape. All requests / responses / events share
/// the `seq` + `type` envelope.
///
/// `body` and `arguments` are `[String: Any]?` which can't be `Sendable`
/// at the type level. We mark the struct `@unchecked Sendable` — every
/// payload we accept or emit is JSON-decoded (`String`, `Int`, `Double`,
/// `Bool`, `[Any]`, `[String:Any]`, `NSNull`), which are all
/// thread-safe to read.
public struct DAPMessage: @unchecked Sendable {
    public enum Kind: String, Sendable { case request, response, event }

    public let seq: Int
    public let kind: Kind
    /// `command` for requests/responses, `event` for events.
    public let name: String
    /// For responses: the request_seq of the original request.
    public let requestSeq: Int?
    public let success: Bool?
    public let message: String?
    public let body: [String: Any]?
    public let arguments: [String: Any]?

    public init(
        seq: Int,
        kind: Kind,
        name: String,
        requestSeq: Int? = nil,
        success: Bool? = nil,
        message: String? = nil,
        body: [String: Any]? = nil,
        arguments: [String: Any]? = nil
    ) {
        self.seq = seq
        self.kind = kind
        self.name = name
        self.requestSeq = requestSeq
        self.success = success
        self.message = message
        self.body = body
        self.arguments = arguments
    }

    public func encode() throws -> Data {
        var dict: [String: Any] = ["seq": seq, "type": kind.rawValue]
        switch kind {
        case .request:
            dict["command"] = name
            if let arguments { dict["arguments"] = arguments }
        case .response:
            dict["command"] = name
            dict["request_seq"] = requestSeq ?? 0
            dict["success"] = success ?? true
            if let message { dict["message"] = message }
            if let body { dict["body"] = body }
        case .event:
            dict["event"] = name
            if let body { dict["body"] = body }
        }
        let json = try JSONSerialization.data(withJSONObject: dict, options: [])
        let header = "Content-Length: \(json.count)\r\n\r\n"
        var framed = Data(header.utf8)
        framed.append(json)
        return framed
    }

    public static func decode(_ data: Data) throws -> DAPMessage {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeStr = obj["type"] as? String,
              let kind = Kind(rawValue: typeStr),
              let seq = obj["seq"] as? Int
        else {
            throw DAPError.malformed("missing seq/type")
        }
        switch kind {
        case .request:
            guard let cmd = obj["command"] as? String else { throw DAPError.malformed("request missing command") }
            return DAPMessage(
                seq: seq, kind: .request, name: cmd,
                arguments: obj["arguments"] as? [String: Any]
            )
        case .response:
            guard let cmd = obj["command"] as? String else { throw DAPError.malformed("response missing command") }
            return DAPMessage(
                seq: seq, kind: .response, name: cmd,
                requestSeq: obj["request_seq"] as? Int,
                success: obj["success"] as? Bool,
                message: obj["message"] as? String,
                body: obj["body"] as? [String: Any]
            )
        case .event:
            guard let evt = obj["event"] as? String else { throw DAPError.malformed("event missing event") }
            return DAPMessage(
                seq: seq, kind: .event, name: evt,
                body: obj["body"] as? [String: Any]
            )
        }
    }
}

public enum DAPError: Error, CustomStringConvertible {
    case malformed(String)
    case eof
    public var description: String {
        switch self {
        case .malformed(let m): return "DAP malformed: \(m)"
        case .eof: return "DAP eof"
        }
    }
}

/// Reads framed DAP messages from a FileHandle. Returns nil at EOF.
public actor DAPReader {
    private let handle: FileHandle
    private var buffer = Data()

    public init(handle: FileHandle) { self.handle = handle }

    public func read() async throws -> DAPMessage? {
        while true {
            if let msg = try extract() { return msg }
            let chunk = try handle.read(upToCount: 4096)
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                return nil
            }
        }
    }

    private func extract() throws -> DAPMessage? {
        // Look for the end of headers (\r\n\r\n).
        guard let sep = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: 0..<sep.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw DAPError.malformed("header not utf8")
        }
        var length: Int = -1
        for line in headerStr.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && parts[0].caseInsensitiveCompare("Content-Length") == .orderedSame {
                length = Int(parts[1]) ?? -1
            }
        }
        guard length >= 0 else { throw DAPError.malformed("missing Content-Length") }
        let bodyStart = sep.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        buffer.removeSubrange(0..<(bodyStart + length))
        return try DAPMessage.decode(body)
    }
}

/// Serializes writes to a FileHandle from any actor.
public actor DAPWriter {
    private let handle: FileHandle
    private var seq = 1

    public init(handle: FileHandle) { self.handle = handle }

    public func nextSeq() -> Int { let s = seq; seq += 1; return s }

    public func send(_ message: DAPMessage) throws {
        let data = try message.encode()
        try handle.write(contentsOf: data)
    }

    public func reply(to request: DAPMessage, body: [String: Any]? = nil, success: Bool = true, message: String? = nil) throws {
        let s = nextSeq()
        let resp = DAPMessage(
            seq: s, kind: .response, name: request.name,
            requestSeq: request.seq, success: success, message: message, body: body
        )
        try send(resp)
    }

    public func event(_ name: String, body: [String: Any]? = nil) throws {
        let s = nextSeq()
        let evt = DAPMessage(seq: s, kind: .event, name: name, body: body)
        try send(evt)
    }
}
