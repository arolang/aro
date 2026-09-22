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
public struct LMChatRequest: Encodable, Sendable {
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
    /// Ceiling on the tokens this reply may generate (GitLab #869).
    ///
    /// A reservation, not a target. When the prompt has grown, the
    /// reservation is what gives way — an answer written in 4 000 tokens
    /// instead of 16 384 is the same answer, and a request refused for
    /// exceeding the window is no answer at all. `nil` leaves each backend's
    /// own default in place.
    public var maxTokens: Int?
    /// Nucleus mass kept after truncation (GitLab #877). `nil` leaves the
    /// backend's own default.
    public var topP: Double?
    /// Top-k cutoff applied before sampling (GitLab #877).
    public var topK: Int?
    /// A tool this request must call (GitLab #873).
    ///
    /// Rendered as OpenAI's named `tool_choice`, which llama-server and
    /// vLLM both honour. It takes the third option away: the model may not
    /// answer instead. Backends that cannot express it ignore it and the
    /// prose instruction in the prompt stands, so this degrades rather than
    /// fails.
    public var forcedToolCall: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, temperature, stream
        case maxTokens = "max_tokens"
        case topP = "top_p"
        case topK = "top_k"
        case toolChoice = "tool_choice"
    }

    // `tool_choice` is OpenAI's nested object rather than a bare string, so
    // the encoding is written out instead of synthesised.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encodeIfPresent(tools, forKey: .tools)
        try c.encodeIfPresent(temperature, forKey: .temperature)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(topP, forKey: .topP)
        try c.encodeIfPresent(topK, forKey: .topK)
        if let forced = forcedToolCall {
            var choice = c.nestedContainer(keyedBy: ToolChoiceKeys.self, forKey: .toolChoice)
            try choice.encode("function", forKey: .type)
            var function = choice.nestedContainer(keyedBy: ToolChoiceFunctionKeys.self,
                                                  forKey: .function)
            try function.encode(forced, forKey: .name)
        }
    }

    private enum ToolChoiceKeys: String, CodingKey { case type, function }
    private enum ToolChoiceFunctionKeys: String, CodingKey { case name }
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
    /// The server's own token accounting for this exchange, where it
    /// reports one (GitLab #870).
    public var usage: LMUsage?
}

/// What a backend counted for one exchange.
///
/// `promptTokens` is the number that matters here: it is the tokenizer's
/// count of the very body that was sent, which is the only honest answer to
/// "how big is this conversation" and the one a character-based estimate is
/// guessing at.
public struct LMUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// A chat-completion backend.
public protocol LMBackend: Sendable {
    var name: String { get }
    var modelIdentifier: String { get }
    func start() async throws
    func stop() async
    func chat(request: LMChatRequest) async throws -> LMChatResponse.Choice.Message

    /// Token accounting for the most recent `chat`, when this backend knows
    /// it (GitLab #870).
    ///
    /// A separate call rather than a changed return type: the message is what
    /// every caller wants and threading a tuple through four backends and
    /// every call site would be a large change for a number only the budget
    /// reads. Backends that cannot count return `nil` and the budget keeps
    /// using its estimate, so this is additive.
    func usageOfLastChat() async -> LMUsage?
}

public extension LMBackend {
    func usageOfLastChat() async -> LMUsage? { nil }
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
