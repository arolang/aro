// ============================================================
// LMTool.swift
// AROLM - tool descriptor + registry for model-facing tools
// ============================================================

import Foundation

/// A tool the language model can invoke during a chat turn.
///
/// Implementations are value-based closures instead of per-type protocols so
/// registration stays short and the registry can hold built-in and
/// MCP-bridged tools in the same collection.
public struct LMToolDescriptor: Sendable {
    public let name: String
    public let description: String
    /// JSON schema for the `function.parameters` field in the OpenAI tool
    /// definition. Must be a `JSONValue.object`.
    public let parameters: JSONValue
    public let execute: @Sendable (JSONValue) async throws -> String

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
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

public enum LMToolError: Error, CustomStringConvertible {
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
