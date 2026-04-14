// ============================================================
// LMBackend.swift
// AROLM - backend abstraction for chat completions
// ============================================================

import Foundation

/// A tool the model is allowed to call during a chat turn.
public struct LMToolDefinition: Codable, Sendable, Equatable {
    public struct Function: Codable, Sendable, Equatable {
        public var name: String
        public var description: String
        public var parameters: JSONValue
        public init(name: String, description: String, parameters: JSONValue) {
            self.name = name
            self.description = description
            self.parameters = parameters
        }
    }
    public var type: String
    public var function: Function
    public init(function: Function) {
        self.type = "function"
        self.function = function
    }
}

/// A tool call returned by the assistant.
public struct LMToolCall: Codable, Sendable, Equatable {
    public struct FunctionCall: Codable, Sendable, Equatable {
        public var name: String
        /// JSON-encoded arguments string (OpenAI format).
        public var arguments: String
        public init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }
    }
    public var id: String
    public var type: String
    public var function: FunctionCall
    public init(id: String, function: FunctionCall) {
        self.id = id
        self.type = "function"
        self.function = function
    }
}

/// Request sent to `/v1/chat/completions`.
public struct LMChatRequest: Codable, Sendable {
    public struct Message: Codable, Sendable {
        public var role: String
        public var content: String?
        public var name: String?
        public var toolCallId: String?
        public var toolCalls: [LMToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content, name
            case toolCallId = "tool_call_id"
            case toolCalls = "tool_calls"
        }
    }
    public var model: String
    public var messages: [Message]
    public var tools: [LMToolDefinition]?
    public var temperature: Double?
    public var stream: Bool?
}

/// Response from `/v1/chat/completions`.
public struct LMChatResponse: Codable, Sendable {
    public struct Choice: Codable, Sendable {
        public struct Message: Codable, Sendable {
            public var role: String
            public var content: String?
            public var toolCalls: [LMToolCall]?
            enum CodingKeys: String, CodingKey {
                case role, content
                case toolCalls = "tool_calls"
            }
        }
        public var index: Int?
        public var message: Message
        public var finishReason: String?
        enum CodingKeys: String, CodingKey {
            case index, message
            case finishReason = "finish_reason"
        }
    }
    public var choices: [Choice]
}

/// A chat-completion backend. Implementations either speak to a local runner
/// process (llama.cpp / mlx_lm.server) or to a remote OpenAI-compatible
/// endpoint.
public protocol LMBackend: Sendable {
    /// Human-readable backend name for `/model`.
    var name: String { get }

    /// The model identifier the backend will send.
    var modelIdentifier: String { get }

    /// Ensure the backend is ready (spawn runner, check endpoint, etc.).
    func start() async throws

    /// Stop the backend (terminate runner).
    func stop() async

    /// Execute one chat turn. Returns the assistant message.
    func chat(request: LMChatRequest) async throws -> LMChatResponse.Choice.Message
}

public enum LMBackendError: Error, CustomStringConvertible {
    case noBackendAvailable
    case runnerNotFound(String)
    case httpError(Int, String)
    case invalidResponse(String)
    case notStarted

    public var description: String {
        switch self {
        case .noBackendAvailable:
            return "No LM backend is available. Install llama.cpp (llama-server) or mlx_lm, or set ARO_LM_ENDPOINT."
        case .runnerNotFound(let name):
            return "Runner '\(name)' not found on PATH"
        case .httpError(let code, let body):
            return "LM backend HTTP \(code): \(body)"
        case .invalidResponse(let msg):
            return "Invalid LM backend response: \(msg)"
        case .notStarted:
            return "LM backend was used before start() was called"
        }
    }
}
