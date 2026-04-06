// ============================================================
// ShellTool.swift
// AROLM - approval-gated shell command tool
// ============================================================

import Foundation

/// Approval policy for `run_shell`. In interactive mode the session asks the
/// user for each command; with `--yes` it approves everything.
public protocol ShellApprover: Sendable {
    func approve(command: String) async -> Bool
}

public struct AutoApprove: ShellApprover {
    public init() {}
    public func approve(command: String) async -> Bool { true }
}

public struct DenyAll: ShellApprover {
    public init() {}
    public func approve(command: String) async -> Bool { false }
}

public enum ShellTool {
    public static func tool(
        guard pathGuard: PathGuard,
        approver: ShellApprover
    ) -> LMToolDescriptor {
        let params: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to execute inside the working directory")
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string("Seconds before the command is killed (default 60)")
                ])
            ]),
            "required": .array([.string("command")])
        ])
        return LMToolDescriptor(
            name: "run_shell",
            description: "Execute a shell command in the working directory. Requires per-call approval in interactive mode.",
            parameters: params
        ) { args in
            guard let command = args["command"]?.stringValue else {
                throw LMToolError.invalidArguments("missing 'command'")
            }
            let approved = await approver.approve(command: command)
            guard approved else {
                throw LMToolError.userDenied("shell command: \(command)")
            }
            let timeout = TimeInterval(args["timeout"]?.intValue ?? 60)
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
            let result = try ProcessRunner.runAndCapture(
                executable: shell,
                arguments: ["-c", command],
                cwd: pathGuard.root,
                timeout: timeout
            )
            var lines: [String] = []
            lines.append("exit: \(result.exitCode)")
            if !result.stdout.isEmpty {
                lines.append("--- stdout ---")
                lines.append(result.stdout)
            }
            if !result.stderr.isEmpty {
                lines.append("--- stderr ---")
                lines.append(result.stderr)
            }
            return lines.joined(separator: "\n")
        }
    }
}
