// ============================================================
// ToolRegistry.swift
// AROLM - dispatch table for LMTool descriptors
// ============================================================

import Foundation

/// In-memory registry mapping tool name → descriptor. Holds both built-in
/// tools and tools bridged from an MCP server.
public actor ToolRegistry {
    private var tools: [String: LMToolDescriptor] = [:]

    public init() {}

    public func register(_ tool: LMToolDescriptor) {
        tools[tool.name] = tool
    }

    public func register(_ collection: [LMToolDescriptor]) {
        for t in collection { tools[t.name] = t }
    }

    public func list() -> [LMToolDescriptor] {
        tools.values.sorted { $0.name < $1.name }
    }

    public func definitions() -> [LMToolDefinition] {
        list().map { $0.toolDefinition }
    }

    /// Look up a tool by name.
    public func tool(named name: String) -> LMToolDescriptor? {
        tools[name]
    }

    /// Dispatch a tool call. `argumentsJSON` is the OpenAI-format JSON string
    /// coming back from the model.
    public func dispatch(name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tools[name] else {
            throw LMToolError.unknownTool(name)
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.decode(from: argumentsJSON)
        } catch {
            throw LMToolError.invalidArguments(error.localizedDescription)
        }
        return try await tool.execute(parsed)
    }
}
