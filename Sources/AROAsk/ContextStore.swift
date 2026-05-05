// ============================================================
// ContextStore.swift
// AROAsk - per-directory conversation persistence
// ============================================================

import Foundation
import Yams

/// A single message in the conversation history.
public struct AskMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var name: String?
    public var toolCallId: String?
    public var toolCalls: String?  // JSON-encoded [LMToolCall]

    public init(
        role: String,
        content: String? = nil,
        name: String? = nil,
        toolCallId: String? = nil,
        toolCalls: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallId = toolCallId
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCallId = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

/// MCP server configuration persisted in .context.
public struct MCPServerConfig: Codable, Sendable {
    public var command: String
    public var args: [String]
    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }
}

/// The full context document stored as `.context` YAML.
public struct AskContext: Codable, Sendable {
    public var model: String
    public var created: Date
    public var messages: [AskMessage]
    public var mcpServers: [MCPServerConfig]?

    public init(model: String) {
        self.model = model
        self.created = Date()
        self.messages = [
            AskMessage(role: "system", content: Self.resolvedSystemPrompt())
        ]
    }

    /// Resolve the system prompt for this session, in priority order:
    ///   1. `$ARO_SYSTEM_PROMPT_FILE` env var (explicit path override)
    ///   2. `$cwd/aro_system_prompt.txt`     (project-specific override)
    ///   3. `<exe>/../share/aro/aro_system_prompt.txt`  (installed builds)
    ///   4. `<exe>/../../Train/release/aro_system_prompt.txt` (dev checkout)
    ///   5. `defaultSystemPrompt` baked-in fallback
    ///
    /// The model was trained against the long version in
    /// `Train/release/aro_system_prompt.txt` (50+ worked examples + full
    /// action reference). The baked-in default is a richer fallback than
    /// the original ~30-line prompt, but still much shorter than what the
    /// model expects, so loading the training prompt at runtime is the
    /// most faithful behaviour.
    public static func resolvedSystemPrompt() -> String {
        let fm = FileManager.default

        if let path = ProcessInfo.processInfo.environment["ARO_SYSTEM_PROMPT_FILE"],
           !path.isEmpty,
           let text = try? String(contentsOfFile: path, encoding: .utf8),
           !text.isEmpty {
            return text
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let cwdPrompt = cwd.appendingPathComponent("aro_system_prompt.txt")
        if fm.fileExists(atPath: cwdPrompt.path),
           let text = try? String(contentsOf: cwdPrompt, encoding: .utf8),
           !text.isEmpty {
            return text
        }

        let exe = URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/bin/aro")
            .resolvingSymlinksInPath()
        let exeDir = exe.deletingLastPathComponent()
        let candidates = [
            exeDir.appendingPathComponent("../share/aro/aro_system_prompt.txt").standardized,
            exeDir.appendingPathComponent("../../Train/release/aro_system_prompt.txt").standardized,
        ]
        for url in candidates {
            if fm.fileExists(atPath: url.path),
               let text = try? String(contentsOf: url, encoding: .utf8),
               !text.isEmpty {
                return text
            }
        }

        return defaultSystemPrompt
    }

    /// Richer baked-in fallback. Used only when no `aro_system_prompt.txt`
    /// is found on disk. Includes the structural rules + a handful of
    /// worked examples covering the patterns the model regresses on most
    /// (feature-set wrapper, Application-Start, event handler, OpenAPI
    /// route, repository observer).
    public static let defaultSystemPrompt = """
    You are an expert ARO (Action Result Object) coding assistant invoked via `aro ask`.

    ARO is a DSL where every statement is `Verb the <Result> preposition [the] <Object>.`
    All ARO code MUST live inside a feature set:

        (FeatureSetName: BusinessActivity) {
            Statement1.
            Statement2.
            Return ...  (or)  Throw ...
        }

    Hard rules — fragments outside a feature set will fail `aro check`:

    - Every feature set has a header `(name: activity)` followed by `{ ... }`.
    - Every statement ends with a period.
    - Every result and object is angle-bracketed: `<id>`, `<user-repository>`.
    - Articles `the`/`a`/`an` are required before result/object names.
    - Every feature set ends with a Return or Throw.
    - Use only known ARO actions (Extract, Compute, Retrieve, Store, Return,
      Log, Emit, Publish, Send, Render, Start, Stop, Keepalive, Configure,
      Accept, For-each, When, Read, Write, Compare, Throw, ...).
    - Do NOT invent verbs and do NOT use the literal word "preposition".

    WORKED EXAMPLES:

    Hello world (Application-Start):
    ```aro
    (Application-Start: Hello World) {
        Log "Hello, World!" to the <console>.
        Return an <OK: status> for the <startup>.
    }
    ```

    HTTP route handler (operationId from openapi.yaml):
    ```aro
    (getUser: User API) {
        Extract the <id> from the <pathParameters: id>.
        Retrieve the <user> from the <user-repository> where id = <id>.
        Return an <OK: status> with <user>.
    }
    ```

    Event emitter + handler:
    ```aro
    (createUser: User API) {
        Extract the <data> from the <request: body>.
        Create the <user> with <data>.
        Emit a <UserCreated: event> with <user>.
        Return a <Created: status> with <user>.
    }

    (Send Welcome Email: UserCreated Handler) {
        Extract the <user> from the <event: user>.
        Send the <welcome-email> to the <user: email>.
        Return an <OK: status> for the <notification>.
    }
    ```

    Long-running server (Keepalive):
    ```aro
    (Application-Start: HTTP Server) {
        Start the <http-server> with <contract>.
        Keepalive the <application> for the <events>.
        Return an <OK: status> for the <startup>.
    }
    ```

    Repository observer:
    ```aro
    (Audit Order Changes: order-repository Observer) {
        Extract the <order> from the <event: order>.
        Log <order> to the <audit-log>.
        Return an <OK: status> for the <audit>.
    }
    ```

    RESPONSE BEHAVIOUR:
    - When asked to WRITE, CREATE, or BUILD something: produce a complete
      feature set inside ```aro fences. Then use your tools to write files
      and validate with `aro_check`.
    - When asked a QUESTION about ARO: answer in plain prose. ARO snippets
      in answers are illustrative — they don't need to be runnable, but
      always show the feature-set wrapper around any non-trivial example.
    - When asked to FIX an error: read the file with `read_file`, propose a
      fix, apply it with `edit_file`, and validate with `aro_check`.
    - When asked to EXPLAIN: read the code with `read_file` and explain in
      prose. Don't paraphrase by re-emitting the file.

    Tools are invoked via the JSON tool-call protocol. NEVER write a tool
    name as text inside an ```aro``` block (e.g. `read_file("foo")`); that
    is not ARO syntax and will fail `aro check`.
    """
}

/// Reads and writes `.context` YAML in the working directory.
public struct ContextStore: Sendable {
    public let workingDirectory: URL
    private var contextURL: URL { workingDirectory.appendingPathComponent(".context") }

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    public func load() throws -> AskContext? {
        guard FileManager.default.fileExists(atPath: contextURL.path) else { return nil }
        let data = try Data(contentsOf: contextURL)
        let decoder = YAMLDecoder()
        return try decoder.decode(AskContext.self, from: data)
    }

    public func loadOrCreate(model: String) throws -> AskContext {
        try load() ?? AskContext(model: model)
    }

    public func save(_ context: AskContext) throws {
        let encoder = YAMLEncoder()
        let yaml = try encoder.encode(context)
        try Data(yaml.utf8).write(to: contextURL)
    }

    @discardableResult
    public func clear() throws -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: contextURL.path) {
            try fm.removeItem(at: contextURL)
            return true
        }
        return false
    }
}
