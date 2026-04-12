// ============================================================
// ToolRegistry.swift
// AROAsk - dispatch table for tool descriptors
// ============================================================

import Foundation

/// In-memory registry mapping tool name -> descriptor.
public actor ToolRegistry {
    private var tools: [String: AskToolDescriptor] = [:]

    public init() {}

    public func register(_ tool: AskToolDescriptor) {
        tools[tool.name] = tool
    }

    public func register(_ collection: [AskToolDescriptor]) {
        for t in collection { tools[t.name] = t }
    }

    public func list() -> [AskToolDescriptor] {
        tools.values.sorted { $0.name < $1.name }
    }

    public func definitions() -> [LMToolDefinition] {
        list().map { $0.toolDefinition }
    }

    public func tool(named name: String) -> AskToolDescriptor? {
        tools[name]
    }

    /// Dispatch a tool call. Returns the tool output string.
    public func dispatch(
        name: String,
        argumentsJSON: String,
        approver: ToolApprover
    ) async throws -> String {
        guard let tool = tools[name] else {
            throw AskToolError.unknownTool(name)
        }
        let parsed: JSONValue
        do {
            parsed = try JSONValue.decode(from: argumentsJSON)
        } catch {
            throw AskToolError.invalidArguments(error.localizedDescription)
        }

        // Require user approval for dangerous tools
        if tool.requiresApproval {
            let approved = await approver.approve(
                toolName: name,
                description: tool.description,
                arguments: argumentsJSON
            )
            guard approved else {
                throw AskToolError.userDenied("tool: \(name)")
            }
        }

        return try await tool.execute(parsed)
    }
}

/// Approval policy for tools that modify files or run commands.
public protocol ToolApprover: Sendable {
    func approve(toolName: String, description: String, arguments: String) async -> Bool
}

public struct AutoApproveAll: ToolApprover {
    public init() {}
    public func approve(toolName: String, description: String, arguments: String) async -> Bool { true }
}

public struct DenyAllApprover: ToolApprover {
    public init() {}
    public func approve(toolName: String, description: String, arguments: String) async -> Bool { false }
}
