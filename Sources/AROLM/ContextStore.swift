// ============================================================
// ContextStore.swift
// AROLM - per-directory conversation context (.context YAML)
// ============================================================

import Foundation
import Yams

/// A single chat message in a persisted conversation.
///
/// Mirrors the OpenAI chat-completions message schema so that the same value
/// can be sent to `/v1/chat/completions` without transformation.
public struct LMMessage: Codable, Sendable, Equatable {
    public var role: String          // "system" | "user" | "assistant" | "tool"
    public var content: String?
    public var name: String?
    public var toolCallId: String?
    /// Raw JSON array string containing OpenAI-shaped tool_calls.
    /// Persisted as a string so YAML stays readable and the bridge doesn't
    /// need a recursive `AnyCodable` tree.
    public var toolCalls: String?

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
        case role
        case content
        case name
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

/// Declaration of an external MCP server the session should bridge to.
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }
}

/// Top-level persisted context document.
public struct LMContext: Codable, Sendable, Equatable {
    public var model: String
    public var created: Date
    public var messages: [LMMessage]
    public var mcpServers: [MCPServerConfig]?

    public init(
        model: String,
        created: Date = Date(),
        messages: [LMMessage] = [],
        mcpServers: [MCPServerConfig]? = nil
    ) {
        self.model = model
        self.created = created
        self.messages = messages
        self.mcpServers = mcpServers
    }

    enum CodingKeys: String, CodingKey {
        case model
        case created
        case messages
        case mcpServers = "mcp_servers"
    }
}

/// Loads, updates and atomically persists an `LMContext` in a `.context` file
/// located in the current working directory.
public final class ContextStore: @unchecked Sendable {
    public let contextPath: URL
    public let workingDirectory: URL
    private let lock = NSLock()

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
        self.contextPath = workingDirectory.appendingPathComponent(".context")
    }

    /// Default system prompt injected the first time a session is started.
    public static let defaultSystemPrompt = """
    You are ARO-Coder, an assistant specialised in the ARO programming language.

    ARO expresses business features as Action-Result-Object statements grouped
    into feature sets. Feature sets are triggered by events, not called
    directly. HTTP routes are defined contract-first via openapi.yaml. An ARO
    application is a directory of .aro files; all feature sets are globally
    visible inside one application.

    A statement has the shape:
        Action the <Result: qualifier> preposition the <Object: qualifier>.

    Action roles:
      REQUEST  - Extract, Parse, Retrieve, Fetch  (external -> internal)
      OWN      - Compute, Validate, Compare, Create, Transform
      RESPONSE - Return, Throw                   (internal -> external)
      EXPORT   - Publish, Store, Log, Send, Emit

    When the user asks for code, produce ARO source wrapped in markdown fences.
    You have access to tools for reading the project, running `aro check`,
    running tests, and searching proposals. Prefer calling tools over guessing
    when you need factual information about the project.
    """

    /// Load the context from disk, or return nil if no `.context` file exists.
    public func load() throws -> LMContext? {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: contextPath.path) else {
            return nil
        }
        let data = try Data(contentsOf: contextPath)
        guard let yaml = String(data: data, encoding: .utf8) else {
            return nil
        }
        let decoder = YAMLDecoder()
        return try decoder.decode(LMContext.self, from: yaml)
    }

    /// Load the context, or create a fresh one with the default system prompt.
    public func loadOrCreate(model: String) throws -> LMContext {
        if let existing = try load() {
            return existing
        }
        return LMContext(
            model: model,
            messages: [
                LMMessage(role: "system", content: Self.defaultSystemPrompt)
            ]
        )
    }

    /// Persist a context atomically. File is written with mode 0600.
    public func save(_ context: LMContext) throws {
        lock.lock()
        defer { lock.unlock() }

        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(context)
        let data = Data(yaml.utf8)

        let tmp = contextPath.deletingLastPathComponent()
            .appendingPathComponent(".context.tmp")
        try data.write(to: tmp, options: [.atomic])
        // Restrict permissions before moving into place.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: tmp.path
        )
        if FileManager.default.fileExists(atPath: contextPath.path) {
            try FileManager.default.removeItem(at: contextPath)
        }
        try FileManager.default.moveItem(at: tmp, to: contextPath)
    }

    /// Remove the `.context` file.
    @discardableResult
    public func clear() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: contextPath.path) else {
            return false
        }
        try FileManager.default.removeItem(at: contextPath)
        return true
    }
}
