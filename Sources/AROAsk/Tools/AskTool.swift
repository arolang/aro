// ============================================================
// AskTool.swift
// AROAsk - tool descriptor + error types
// ============================================================

import Foundation

/// A tool the language model can invoke during a chat turn.
/// Closure-based descriptors so both built-in and MCP-bridged tools
/// live in the same registry.
public struct AskToolDescriptor: Sendable {
    public let name: String
    public let description: String
    /// JSON schema for the `function.parameters` field.
    public let parameters: JSONValue
    /// Whether this tool requires user confirmation before execution.
    public let requiresApproval: Bool
    public let execute: @Sendable (JSONValue) async throws -> String

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        requiresApproval: Bool = false,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.requiresApproval = requiresApproval
        self.execute = execute
    }

    public var toolDefinition: LMToolDefinition {
        LMToolDefinition(function: .init(
            name: name,
            description: description,
            parameters: parameters
        ))
    }
}

public enum AskToolError: Error, CustomStringConvertible {
    case unknownTool(String)
    case invalidArguments(String)
    case pathOutsideRoot(String)
    case userDenied(String)
    case executionFailed(String)

    public var description: String {
        switch self {
        case .unknownTool(let n): return "Unknown tool '\(n)'"
        case .invalidArguments(let m): return "Invalid tool arguments: \(m)"
        case .pathOutsideRoot(let p): return "Path '\(p)' is outside the working directory"
        case .userDenied(let m): return "User denied: \(m)"
        case .executionFailed(let m): return "Tool execution failed: \(m)"
        }
    }
}
