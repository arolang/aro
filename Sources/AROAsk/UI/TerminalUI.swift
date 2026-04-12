// ============================================================
// TerminalUI.swift
// AROAsk - terminal formatting and interactive approval
// ============================================================

import Foundation

/// ANSI color codes for terminal output.
public enum Style {
    public static let reset     = "\u{001B}[0m"
    public static let bold      = "\u{001B}[1m"
    public static let dim       = "\u{001B}[2m"
    public static let italic    = "\u{001B}[3m"
    public static let underline = "\u{001B}[4m"

    public static let red       = "\u{001B}[31m"
    public static let green     = "\u{001B}[32m"
    public static let yellow    = "\u{001B}[33m"
    public static let blue      = "\u{001B}[34m"
    public static let magenta   = "\u{001B}[35m"
    public static let cyan      = "\u{001B}[36m"
    public static let white     = "\u{001B}[37m"

    public static let bgRed     = "\u{001B}[41m"
    public static let bgGreen   = "\u{001B}[42m"
    public static let bgYellow  = "\u{001B}[43m"
    public static let bgBlue    = "\u{001B}[44m"

    public static func color(_ text: String, _ color: String) -> String {
        "\(color)\(text)\(reset)"
    }
}

/// Interactive terminal approver that shows tool details and asks y/N.
public struct InteractiveApprover: ToolApprover {
    public init() {}

    public func approve(toolName: String, description: String, arguments: String) async -> Bool {
        let stderr = FileHandle.standardError

        stderr.write(Data("\n".utf8))
        stderr.write(Data("\(Style.bgYellow)\(Style.bold) APPROVE \(Style.reset) ".utf8))
        stderr.write(Data("\(Style.yellow)\(toolName)\(Style.reset)\n".utf8))

        // Pretty-print the arguments
        if let data = arguments.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
           let prettyStr = String(data: pretty, encoding: .utf8) {
            for line in prettyStr.split(separator: "\n") {
                stderr.write(Data("  \(Style.dim)\(line)\(Style.reset)\n".utf8))
            }
        } else {
            stderr.write(Data("  \(Style.dim)\(arguments.prefix(300))\(Style.reset)\n".utf8))
        }

        stderr.write(Data("\(Style.bold)Allow? [y/N] \(Style.reset)".utf8))

        guard let line = readLine() else { return false }
        return line.lowercased().hasPrefix("y")
    }
}

/// Prints formatted output for the `aro ask` interface.
public enum TerminalUI {

    public static func printBanner() {
        let stderr = FileHandle.standardError
        stderr.write(Data("""
        \(Style.bold)\(Style.cyan)
          ╭─────────────────────────────────╮
          │  \(Style.white)aro ask\(Style.cyan)  — ARO Coding Assistant  │
          ╰─────────────────────────────────╯\(Style.reset)

        """.utf8))
    }

    public static func printHelp() {
        print("""
        \(Style.bold)COMMANDS\(Style.reset)
          \(Style.cyan)/help\(Style.reset)             Show this help message
          \(Style.cyan)/fix\(Style.reset)  \(Style.dim)<path>\(Style.reset)      Read, diagnose, and fix errors in the given file
          \(Style.cyan)/explain\(Style.reset) \(Style.dim)<path>\(Style.reset)  Explain what the ARO code does
          \(Style.cyan)/docs\(Style.reset) \(Style.dim)<path>\(Style.reset)     Generate documentation for an ARO application
          \(Style.cyan)/plugin\(Style.reset) \(Style.dim)<name>\(Style.reset)   Scaffold a new plugin interactively
          \(Style.cyan)/openapi\(Style.reset)          Generate an openapi.yaml from a description

        \(Style.bold)SESSION\(Style.reset)
          \(Style.cyan)/clean\(Style.reset)            Delete .context (start fresh)
          \(Style.cyan)/show\(Style.reset)             Print current conversation context
          \(Style.cyan)/tools\(Style.reset)            List all available tools
          \(Style.cyan)/model\(Style.reset)            Show backend and model info
          \(Style.cyan)/mcp\(Style.reset)              List connected MCP servers
          \(Style.cyan)/index\(Style.reset)            (Re)build the project search index
          \(Style.cyan)/search\(Style.reset) \(Style.dim)<query>\(Style.reset)  Search the indexed project

        \(Style.bold)CONTROL\(Style.reset)
          \(Style.cyan)/quit\(Style.reset)             Exit (also: /exit, Ctrl-D)

        \(Style.bold)ONE-SHOT MODE\(Style.reset)
          \(Style.dim)aro ask "write a feature set that greets a user"\(Style.reset)
          \(Style.dim)aro ask /fix ./MyApp/main.aro\(Style.reset)

        \(Style.bold)ENVIRONMENT\(Style.reset)
          \(Style.dim)ARO_ASK_ENDPOINT\(Style.reset)   Override LLM backend URL (OpenAI-compatible)
          \(Style.dim)ARO_ASK_API_KEY\(Style.reset)    API key for the endpoint
          \(Style.dim)ARO_ASK_VERBOSE\(Style.reset)    Show backend runner output
          \(Style.dim)HF_TOKEN\(Style.reset)           Hugging Face token for gated models
        """)
    }

    public static func printToolCall(name: String, args: String) {
        let stderr = FileHandle.standardError
        stderr.write(Data("\(Style.dim)[\(Style.cyan)\(name)\(Style.dim)] ".utf8))
        let preview = args.prefix(100)
        stderr.write(Data("\(preview)\(Style.reset)\n".utf8))
    }

    public static func printToolResult(name: String, output: String) {
        let stderr = FileHandle.standardError
        let lines = output.split(separator: "\n")
        let preview = lines.prefix(5).joined(separator: "\n")
        stderr.write(Data("\(Style.dim)  → \(preview)".utf8))
        if lines.count > 5 {
            stderr.write(Data(" \(Style.dim)(+\(lines.count - 5) lines)\(Style.reset)".utf8))
        }
        stderr.write(Data("\(Style.reset)\n".utf8))
    }

    public static func printError(_ message: String) {
        let stderr = FileHandle.standardError
        stderr.write(Data("\(Style.red)\(Style.bold)error:\(Style.reset) \(Style.red)\(message)\(Style.reset)\n".utf8))
    }

    public static func printStatus(_ message: String) {
        let stderr = FileHandle.standardError
        stderr.write(Data("\(Style.dim)\(message)\(Style.reset)\n".utf8))
    }
}
