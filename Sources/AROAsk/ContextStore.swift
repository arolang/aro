// ============================================================
// ContextStore.swift
// AROAsk - per-directory conversation persistence
// ============================================================

import Foundation
import Yams

/// A single message in the conversation history.
public struct AskMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCallId: String?
    public var toolCalls: String?  // JSON-encoded [LMToolCall]

    public init(
        role: String,
        content: String? = nil,
        name: String? = nil,
        toolCallId: String? = nil,
        toolCalls: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

/// MCP server configuration persisted in .context.
public struct MCPServerConfig: Codable, Sendable {
    public var command: String
    public var args: [String]
    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }
}

/// The full context document stored as `.context` YAML.
public struct AskContext: Codable, Sendable {
    public var model: String
    public var created: Date
    public var messages: [AskMessage]
    public var mcpServers: [MCPServerConfig]?

    public init(model: String) {
        self.model = model
        self.created = Date()
        self.messages = [
            AskMessage(role: "system", content: Self.defaultSystemPrompt)
        ]
    }

    /// Default system prompt baked into every new context.
    public static let defaultSystemPrompt = """
    You are an expert ARO (Action Result Object) coding assistant invoked via `aro ask`.

    ARO is a DSL where every statement follows: Verb the <Result> preposition [the] <Object>.

    You have tools to read, write, and edit files in the user's project directory.
    You can run `aro check`, `aro run`, `aro test`, and `aro build`.
    You can create plugins, generate OpenAPI contracts, and write documentation.

    RESPONSE BEHAVIOUR:
    - When asked to WRITE, CREATE, or BUILD something: produce valid ARO code in ```aro fences.
      Then use your tools to write the files. Always validate with aro_check after writing.
    - When asked a QUESTION about ARO: answer from your knowledge. Include short examples.
    - When asked to FIX an error: read the relevant files, diagnose the issue, propose a fix,
      and apply it with edit_file. Then validate with aro_check.
    - When asked to EXPLAIN: read the code and provide a clear explanation.

    Always produce syntactically valid ARO. Do not invent actions or prepositions.
    """
}

/// Reads and writes `.context` YAML in the working directory.
public struct ContextStore: Sendable {
    public let workingDirectory: URL
    private var contextURL: URL { workingDirectory.appendingPathComponent(".context") }

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    public func load() throws -> AskContext? {
        guard FileManager.default.fileExists(atPath: contextURL.path) else { return nil }
        let data = try Data(contentsOf: contextURL)
        let decoder = YAMLDecoder()
        return try decoder.decode(AskContext.self, from: data)
    }

    public func loadOrCreate(model: String) throws -> AskContext {
        try load() ?? AskContext(model: model)
    }

    public func save(_ context: AskContext) throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(context)
        try Data(yaml.utf8).write(to: contextURL)
    }

    @discardableResult
    public func clear() throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: contextURL.path) {
            try fm.removeItem(at: contextURL)
            return true
        }
        return false
    }
}
