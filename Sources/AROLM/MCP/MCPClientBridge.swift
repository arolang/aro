// ============================================================
// MCPClientBridge.swift
// AROLM - bridges a stdio MCP server into the LM tool registry
// ============================================================

import Foundation

/// Connects to a Model Context Protocol server over stdio and exposes each
/// of its tools (and `resources/read`) as an `LMToolDescriptor` that can be
/// registered alongside the built-in tools.
///
/// Used by `LMSession` to connect to `aro mcp` by default, and to any
/// additional MCP servers listed in `.context` under `mcp_servers:`.
public actor MCPClientBridge {
    public let command: String
    public let args: [String]
    public private(set) var label: String
    private var process: Process?
    private var inPipe: Pipe?
    private var outPipe: Pipe?
    private var nextID: Int = 1
    private var isInitialized = false
    private var buffer = Data()

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
        self.label = (command as NSString).lastPathComponent
    }

    public func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args
        let stdin = Pipe()
        let stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        self.process = p
        self.inPipe = stdin
        self.outPipe = stdout
        try await initialize()
    }

    public func stop() async {
        process?.terminate()
        process = nil
    }

    /// Perform the MCP handshake.
    private func initialize() async throws {
        let params: JSONValue = .object([
            "protocolVersion": .string("2025-06-18"),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string("aro-lm"),
                "version": .string("0.1.0")
            ])
        ])
        _ = try await request(method: "initialize", params: params)
        try sendNotification(method: "notifications/initialized", params: .object([:]))
        isInitialized = true
    }

    /// List all tools exposed by the bridged MCP server and translate them
    /// into `LMToolDescriptor`s. Tool names are prefixed with the bridge
    /// label to avoid collisions.
    public func listTools() async throws -> [LMToolDescriptor] {
        let response = try await request(method: "tools/list", params: .object([:]))
        guard let tools = response["tools"]?.arrayValue else { return [] }
        let prefix = label.replacingOccurrences(of: "-", with: "_")
        var descriptors: [LMToolDescriptor] = []
        for t in tools {
            guard let obj = t.objectValue,
                  let name = obj["name"]?.stringValue else { continue }
            let description = obj["description"]?.stringValue ?? ""
            let params = obj["inputSchema"] ?? .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
            let bridgedName = "\(prefix)_\(name)"
            let capturedName = name
            let bridge = self
            descriptors.append(LMToolDescriptor(
                name: bridgedName,
                description: "[mcp:\(label)] \(description)",
                parameters: params
            ) { args in
                try await bridge.callTool(name: capturedName, arguments: args)
            })
        }
        return descriptors
    }

    /// Forward a tools/call to the bridged server.
    public func callTool(name: String, arguments: JSONValue) async throws -> String {
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": arguments
        ])
        let response = try await request(method: "tools/call", params: params)
        if let content = response["content"]?.arrayValue {
            var parts: [String] = []
            for item in content {
                if let obj = item.objectValue,
                   obj["type"]?.stringValue == "text",
                   let text = obj["text"]?.stringValue {
                    parts.append(text)
                }
            }
            return parts.joined(separator: "\n")
        }
        return try response.encodedString()
    }

    // MARK: - JSON-RPC plumbing

    private func request(method: String, params: JSONValue) async throws -> JSONValue {
        let id = nextID
        nextID += 1
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params
        ])
        try sendMessage(payload)
        while true {
            let message = try await readMessage()
            if let idValue = message["id"], case .int(let mid) = idValue, mid == id {
                if let err = message["error"] {
                    throw LMToolError.executionFailed("MCP error: \(try err.encodedString())")
                }
                return message["result"] ?? .object([:])
            }
            // Ignore notifications or mismatched ids.
        }
    }

    private func sendNotification(method: String, params: JSONValue) throws {
        let payload: JSONValue = .object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        try sendMessage(payload)
    }

    private func sendMessage(_ payload: JSONValue) throws {
        guard let inPipe = inPipe else {
            throw LMToolError.executionFailed("MCP bridge not started")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(payload)
        data.append(0x0A) // newline
        try inPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage() async throws -> JSONValue {
        guard let outPipe = outPipe else {
            throw LMToolError.executionFailed("MCP bridge not started")
        }
        while true {
            if let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<newlineIdx]
                buffer.removeSubrange(...newlineIdx)
                if lineData.isEmpty { continue }
                return try JSONDecoder().decode(JSONValue.self, from: Data(lineData))
            }
            // Read more data.
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                // Blocking read to wait for data.
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            buffer.append(chunk)
        }
    }
}
