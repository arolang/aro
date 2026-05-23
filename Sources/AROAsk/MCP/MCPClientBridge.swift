// ============================================================
// MCPClientBridge.swift
// AROAsk - bridges stdio MCP servers into tool registry
// ============================================================

import Foundation

/// Spawns an MCP server as a child process and bridges its tools into the
/// `aro ask` tool registry. Performs the MCP initialize/initialized handshake
/// and prefixes bridged tool names with "aro_mcp_".
public actor MCPClientBridge {
    private let command: String
    private let args: [String]
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var requestId: Int = 0

    public var label: String { "\(command) \(args.joined(separator: " "))" }

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }

    public func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command)
        p.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")

        try p.run()
        self.process = p
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading

        // MCP initialize handshake
        let initResponse = try await sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: String],
            "clientInfo": ["name": "aro-ask", "version": "1.0.0"]
        ] as [String: Any])
        _ = initResponse

        // Send initialized notification
        try sendNotification(method: "notifications/initialized")
    }

    public func stop() async {
        if let s = stdin {
            s.closeFile()
        }
        process?.terminate()
        process = nil
    }

    /// List tools from the MCP server and return them as AskToolDescriptors.
    public func listTools() async throws -> [AskToolDescriptor] {
        let response = try await sendRequest(method: "tools/list", params: [:] as [String: String])
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return []
        }

        return tools.compactMap { tool -> AskToolDescriptor? in
            guard let name = tool["name"] as? String,
                  let desc = tool["description"] as? String else { return nil }
            let prefixedName = "aro_mcp_\(name)"
            let schema: JSONValue
            if let inputSchema = tool["inputSchema"],
               let data = try? JSONSerialization.data(withJSONObject: inputSchema),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
                schema = decoded
            } else {
                schema = .object(["type": .string("object")])
            }

            let capturedName = name
            return AskToolDescriptor(
                name: prefixedName,
                description: "[MCP] \(desc)",
                parameters: schema
            ) { [weak self] args in
                guard let self = self else { throw AskToolError.executionFailed("MCP bridge closed") }
                return try await self.callTool(name: capturedName, arguments: args)
            }
        }
    }

    private func callTool(name: String, arguments: JSONValue) async throws -> String {
        let argsData = try JSONEncoder().encode(arguments)
        let argsObj = try JSONSerialization.jsonObject(with: argsData)
        let response = try await sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": argsObj
        ] as [String: Any])
        if let result = response["result"] as? [String: Any],
           let content = result["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text
        }
        return String(describing: response["result"] ?? "no result")
    }

    // MARK: - JSON-RPC (newline-delimited per MCP stdio transport)

    private func sendRequest(method: String, params: Any) async throws -> [String: Any] {
        requestId += 1
        let id = requestId
        try writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ])

        guard let out = stdout else { throw AskToolError.executionFailed("MCP stdout closed") }
        return try readJsonRpcMessage(from: out)
    }

    private func sendNotification(method: String) throws {
        try writeMessage([
            "jsonrpc": "2.0",
            "method": method
        ])
    }

    private func writeMessage(_ message: [String: Any]) throws {
        // MCP stdio: one JSON message per line, no headers. JSON itself
        // MUST NOT contain embedded newlines, so .withoutEscapingSlashes
        // is fine — JSONSerialization never inserts `\n` into output.
        let data = try JSONSerialization.data(withJSONObject: message)
        guard let s = stdin else { throw AskToolError.executionFailed("MCP stdin closed") }
        s.write(data)
        s.write(Data("\n".utf8))
    }

    private func readJsonRpcMessage(from handle: FileHandle) throws -> [String: Any] {
        // Read up to and including the next `\n`. Buffering byte-by-byte is
        // fine here: each MCP exchange is request/response, so we read at
        // most one message per call and the messages are small.
        var lineData = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty {
                // Surface what we got so far — usually empty, but a partial
                // line points at a server crash mid-write.
                let preview = String(data: lineData, encoding: .utf8)?.prefix(200) ?? ""
                throw AskToolError.executionFailed(
                    preview.isEmpty
                        ? "MCP EOF"
                        : "MCP EOF after partial line: \(preview)"
                )
            }
            if byte == Data("\n".utf8) { break }
            lineData.append(byte)
        }
        // Strip a trailing \r if the server happens to send CRLF.
        if lineData.last == 0x0D { lineData.removeLast() }
        guard let json = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw AskToolError.executionFailed("MCP: invalid JSON response")
        }
        return json
    }
}
