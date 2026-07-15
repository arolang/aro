// ============================================================
// AskTool.swift
// AROAsk - tool descriptor + error types
// ============================================================

import Foundation

/// Risk tier a tool falls in. Approvers use this to choose
/// between auto-approve / prompt / always-prompt rather than a
/// single binary "dangerous" flag (#370).
public enum AskToolRiskLevel: Sendable, Equatable {
    /// Side-effect-free reads (file read, list, grep, AST query).
    /// Safe to auto-approve in most policies.
    case readonly
    /// Writes that stay inside the working directory (write_file,
    /// edit_file, etc.). Prompts unless the user opted into
    /// auto-approve for the session.
    case modify
    /// Arbitrary external side effects — shell exec, network,
    /// installer. Always prompts under reasonable policies.
    case execute
}

/// A tool the language model can invoke during a chat turn.
/// Closure-based descriptors so both built-in and MCP-bridged tools
/// live in the same registry.
public struct AskToolDescriptor: Sendable {
    public let name: String
    public let description: String
    /// JSON schema for the `function.parameters` field.
    public let parameters: JSONValue
    /// Risk tier driving the approval policy (#370).
    public let riskLevel: AskToolRiskLevel
    public let execute: @Sendable (JSONValue) async throws -> String

    /// Whether this tool requires user confirmation. Derived
    /// from the risk level: \`.readonly\` tools don't, others do.
    /// Kept as a separate property for backwards-source-compat
    /// with anything that read \`requiresApproval\` directly.
    public var requiresApproval: Bool {
        riskLevel != .readonly
    }

    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        riskLevel: AskToolRiskLevel,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.riskLevel = riskLevel
        self.execute = execute
    }

    /// Legacy initialiser preserving the original bool flag.
    /// \`true\` → \`.modify\` (the closest match to "needs approval");
    /// \`false\` → \`.readonly\`. Callers should migrate to the
    /// risk-level form so \`execute\` tier tools can be gated even
    /// when the user has auto-approved \`.modify\`.
    public init(
        name: String,
        description: String,
        parameters: JSONValue,
        requiresApproval: Bool = false,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.init(
            name: name,
            description: description,
            parameters: parameters,
            riskLevel: requiresApproval ? .modify : .readonly,
            execute: execute
        )
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
