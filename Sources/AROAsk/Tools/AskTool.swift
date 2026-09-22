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
    /// Heading this tool is listed under in the generated catalogue
    /// (GitLab #867). Tools that name no group fall under "Other".
    public let promptGroup: String
    /// One line of usage guidance the `description` cannot carry — a
    /// gotcha, a sensible default, when to prefer a sibling tool. `nil`
    /// when the description already says everything.
    public let promptHint: String?
    /// Whether every turn that produces work must call this tool before
    /// answering. Rendered as a requirement naming the tool — and dropped
    /// automatically when the tool is not attached, which a sentence in a
    /// static prompt could not do.
    public let alwaysQueried: Bool
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
        promptGroup: String = ToolPromptGroup.other,
        promptHint: String? = nil,
        alwaysQueried: Bool = false,
        execute: @escaping @Sendable (JSONValue) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.riskLevel = riskLevel
        self.promptGroup = promptGroup
        self.promptHint = promptHint
        self.alwaysQueried = alwaysQueried
        self.execute = execute
    }

    /// Preferred initialiser (#357): the tool declares its parameters
    /// once as a `ToolParameterSchema`; the LLM-facing JSON schema is
    /// derived from it and the execute closure receives already
    /// validated `ToolArguments` decoded against the same declaration.
    public init(
        name: String,
        description: String,
        schema: ToolParameterSchema,
        riskLevel: AskToolRiskLevel = .readonly,
        promptGroup: String = ToolPromptGroup.other,
        promptHint: String? = nil,
        alwaysQueried: Bool = false,
        execute: @escaping @Sendable (ToolArguments) async throws -> String
    ) {
        self.init(
            name: name,
            description: description,
            parameters: schema.jsonSchema,
            riskLevel: riskLevel,
            promptGroup: promptGroup,
            promptHint: promptHint,
            alwaysQueried: alwaysQueried
        ) { raw in
            try await execute(ToolArguments(raw: raw, schema: schema))
        }
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

    /// This descriptor with its prompt-facing copy applied (GitLab #867).
    public func withPromptCopy(group: String, hint: String?) -> AskToolDescriptor {
        AskToolDescriptor(
            name: name,
            description: description,
            parameters: parameters,
            riskLevel: riskLevel,
            promptGroup: group,
            promptHint: hint,
            alwaysQueried: alwaysQueried,
            execute: execute)
    }

    /// `name(arg, optional?)` — the one-line form the generated catalogue
    /// lists (GitLab #867).
    ///
    /// Derived from `parameters`, the JSON schema, rather than from the
    /// Swift declaration: that is the one field every descriptor has,
    /// including the MCP-bridged ones whose parameters arrive from a
    /// server at runtime and can appear in no hand-written list.
    public var promptSignature: String {
        guard case .object(let schema) = parameters,
              case .object(let properties)? = schema["properties"] else {
            return "\(name)()"
        }
        var required: Set<String> = []
        if case .array(let names)? = schema["required"] {
            for case .string(let n) in names { required.insert(n) }
        }
        // Required first, then optional, each alphabetically: a stable
        // order means a diff of this block is a real change, not a
        // dictionary's iteration order moving around.
        let names = properties.keys.sorted()
        let rendered = names.sorted { a, b in
            let ar = required.contains(a), br = required.contains(b)
            return ar == br ? a < b : ar
        }.map { required.contains($0) ? $0 : "\($0)?" }
        return "\(name)(\(rendered.joined(separator: ", ")))"
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
