// ============================================================
// LMBackend.swift
// AROAsk - backend abstraction for chat completions
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

/// A chat-completion backend.
public protocol LMBackend: Sendable {
    var name: String { get }
    var modelIdentifier: String { get }
    func start() async throws
    func stop() async
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
            #if os(macOS)
            return """
            No LM backend available. On macOS the native MLX backend
            should start automatically. If it fails, install one of:

              brew install llama.cpp       # llama-server (GGUF models)
              ARO_ASK_ENDPOINT=http://...  # remote OpenAI-compatible server
            """
            #else
            return """
            No LM backend available. Install one of:

              llama-server                 # llama.cpp with CUDA (apt/build from source)
              ARO_ASK_ENDPOINT=http://...  # remote OpenAI-compatible server

            On Linux with CUDA, install llama.cpp:
              git clone https://github.com/ggerganov/llama.cpp && cd llama.cpp
              cmake -B build -DGGML_CUDA=ON && cmake --build build --target llama-server
              sudo cp build/bin/llama-server /usr/local/bin/
            """
            #endif
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
