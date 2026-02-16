// ============================================================
// MCPTypes.swift
// ARO MCP - Model Context Protocol Types
// ============================================================

import Foundation

// MARK: - MCP Protocol Version

public enum MCPProtocol {
    public static let version = "2025-06-18"
}

// MARK: - Server Info

public struct MCPServerInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

// MARK: - Client Info

public struct MCPClientInfo: Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

// MARK: - Capabilities

public struct MCPCapabilities: Codable, Sendable {
    public let tools: MCPToolsCapability?
    public let resources: MCPResourcesCapability?
    public let prompts: MCPPromptsCapability?

    public init(
        tools: MCPToolsCapability? = nil,
        resources: MCPResourcesCapability? = nil,
        prompts: MCPPromptsCapability? = nil
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
    }
}

public struct MCPToolsCapability: Codable, Sendable {
    public let listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }
}

public struct MCPResourcesCapability: Codable, Sendable {
    public let subscribe: Bool
    public let listChanged: Bool

    public init(subscribe: Bool = false, listChanged: Bool = false) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

public struct MCPPromptsCapability: Codable, Sendable {
    public let listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }
}

// MARK: - Initialize

public struct MCPInitializeParams: Codable, Sendable {
    public let protocolVersion: String
    public let clientInfo: MCPClientInfo
    public let capabilities: MCPCapabilities?

    public init(protocolVersion: String, clientInfo: MCPClientInfo, capabilities: MCPCapabilities? = nil) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.capabilities = capabilities
    }
}

public struct MCPInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let serverInfo: MCPServerInfo
    public let capabilities: MCPCapabilities

    public init(protocolVersion: String, serverInfo: MCPServerInfo, capabilities: MCPCapabilities) {
        self.protocolVersion = protocolVersion
        self.serverInfo = serverInfo
        self.capabilities = capabilities
    }
}

// MARK: - Tools

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPToolsListResult: Codable, Sendable {
    public let tools: [MCPTool]

    public init(tools: [MCPTool]) {
        self.tools = tools
    }
}

public struct MCPToolCallParams: Codable, Sendable {
    public let name: String
    public let arguments: JSONValue?

    public init(name: String, arguments: JSONValue? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPToolCallResult: Codable, Sendable {
    public let content: [MCPContent]
    public let isError: Bool?

    public init(content: [MCPContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }
}

// MARK: - Resources

public struct MCPResource: Codable, Sendable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?

    public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct MCPResourcesListResult: Codable, Sendable {
    public let resources: [MCPResource]

    public init(resources: [MCPResource]) {
        self.resources = resources
    }
}

public struct MCPResourceReadParams: Codable, Sendable {
    public let uri: String

    public init(uri: String) {
        self.uri = uri
    }
}

public struct MCPResourceContent: Codable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?  // Base64 encoded binary

    public init(uri: String, mimeType: String? = nil, text: String? = nil, blob: String? = nil) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public struct MCPResourceReadResult: Codable, Sendable {
    public let contents: [MCPResourceContent]

    public init(contents: [MCPResourceContent]) {
        self.contents = contents
    }
}

// MARK: - Prompts

public struct MCPPrompt: Codable, Sendable {
    public let name: String
    public let description: String?
    public let arguments: [MCPPromptArgument]?

    public init(name: String, description: String? = nil, arguments: [MCPPromptArgument]? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptArgument: Codable, Sendable {
    public let name: String
    public let description: String?
    public let required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPPromptsListResult: Codable, Sendable {
    public let prompts: [MCPPrompt]

    public init(prompts: [MCPPrompt]) {
        self.prompts = prompts
    }
}

public struct MCPPromptGetParams: Codable, Sendable {
    public let name: String
    public let arguments: [String: String]?

    public init(name: String, arguments: [String: String]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPPromptMessage: Codable, Sendable {
    public let role: String
    public let content: MCPContent

    public init(role: String, content: MCPContent) {
        self.role = role
        self.content = content
    }
}

public struct MCPPromptGetResult: Codable, Sendable {
    public let description: String?
    public let messages: [MCPPromptMessage]

    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

// MARK: - Content Types

public struct MCPContent: Codable, Sendable {
    public let type: String
    public let text: String?
    public let data: String?  // For image/audio (base64)
    public let mimeType: String?

    public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ text: String) -> MCPContent {
        MCPContent(type: "text", text: text)
    }
}

// MARK: - JSON Encoding Helpers

extension MCPInitializeResult {
    public func toJSONValue() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "serverInfo": .object([
                "name": .string(serverInfo.name),
                "version": .string(serverInfo.version)
            ]),
            "capabilities": capabilitiesToJSONValue()
        ])
    }

    private func capabilitiesToJSONValue() -> JSONValue {
        var caps: [String: JSONValue] = [:]

        if let tools = capabilities.tools {
            caps["tools"] = .object(["listChanged": .bool(tools.listChanged)])
        }

        if let resources = capabilities.resources {
            caps["resources"] = .object([
                "subscribe": .bool(resources.subscribe),
                "listChanged": .bool(resources.listChanged)
            ])
        }

        if let prompts = capabilities.prompts {
            caps["prompts"] = .object(["listChanged": .bool(prompts.listChanged)])
        }

        return .object(caps)
    }
}

extension MCPToolsListResult {
    public func toJSONValue() -> JSONValue {
        .object([
            "tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            })
        ])
    }
}

extension MCPToolCallResult {
    public func toJSONValue() -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array(content.map { c in
                var obj: [String: JSONValue] = ["type": .string(c.type)]
                if let text = c.text {
                    obj["text"] = .string(text)
                }
                return .object(obj)
            })
        ]

        if let isError = isError {
            result["isError"] = .bool(isError)
        }

        return .object(result)
    }
}

extension MCPResourcesListResult {
    public func toJSONValue() -> JSONValue {
        .object([
            "resources": .array(resources.map { resource in
                var obj: [String: JSONValue] = [
                    "uri": .string(resource.uri),
                    "name": .string(resource.name)
                ]
                if let desc = resource.description {
                    obj["description"] = .string(desc)
                }
                if let mime = resource.mimeType {
                    obj["mimeType"] = .string(mime)
                }
                return .object(obj)
            })
        ])
    }
}

extension MCPResourceReadResult {
    public func toJSONValue() -> JSONValue {
        .object([
            "contents": .array(contents.map { content in
                var obj: [String: JSONValue] = [
                    "uri": .string(content.uri)
                ]
                if let mime = content.mimeType {
                    obj["mimeType"] = .string(mime)
                }
                if let text = content.text {
                    obj["text"] = .string(text)
                }
                if let blob = content.blob {
                    obj["blob"] = .string(blob)
                }
                return .object(obj)
            })
        ])
    }
}

extension MCPPromptsListResult {
    public func toJSONValue() -> JSONValue {
        .object([
            "prompts": .array(prompts.map { prompt in
                var obj: [String: JSONValue] = [
                    "name": .string(prompt.name)
                ]
                if let desc = prompt.description {
                    obj["description"] = .string(desc)
                }
                if let args = prompt.arguments {
                    obj["arguments"] = .array(args.map { arg in
                        var argObj: [String: JSONValue] = [
                            "name": .string(arg.name)
                        ]
                        if let desc = arg.description {
                            argObj["description"] = .string(desc)
                        }
                        if let required = arg.required {
                            argObj["required"] = .bool(required)
                        }
                        return .object(argObj)
                    })
                }
                return .object(obj)
            })
        ])
    }
}

extension MCPPromptGetResult {
    public func toJSONValue() -> JSONValue {
        var result: [String: JSONValue] = [
            "messages": .array(messages.map { msg in
                var contentObj: [String: JSONValue] = ["type": .string(msg.content.type)]
                if let text = msg.content.text {
                    contentObj["text"] = .string(text)
                }
                return .object([
                    "role": .string(msg.role),
                    "content": .object(contentObj)
                ])
            })
        ]

        if let desc = description {
            result["description"] = .string(desc)
        }

        return .object(result)
    }
}
