// ============================================================
// ShellTool.swift
// AROAsk - approval-gated shell command tool
// ============================================================

import Foundation

public enum ShellTool {
    public static func tool(guard pathGuard: PathGuard) -> AskToolDescriptor {
        AskToolDescriptor(
            name: "run_shell",
            description: "Execute a shell command in the working directory. Returns exit code, stdout, and stderr.",
            schema: ToolParameterSchema([
                .required("command", .string, "The shell command to execute"),
                .optional("timeout", .integer, "Timeout in seconds (default 60)"),
            ]),
            riskLevel: .modify
        ) { args in
            let command = try args.requireString("command")
            let timeout = args.int("timeout") ?? 60

            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"

            let result = try ProcessRunner.runAndCapture(
                executable: shell,
                arguments: ["-c", command],
                cwd: pathGuard.root,
                timeout: TimeInterval(timeout)
            )

            var output = "exit code: \(result.exitCode)\n"
            if !result.stdout.isEmpty {
                output += "stdout:\n\(result.stdout)"
            }
            if !result.stderr.isEmpty {
                output += "stderr:\n\(result.stderr)"
            }
            return output
        }
    }
}
