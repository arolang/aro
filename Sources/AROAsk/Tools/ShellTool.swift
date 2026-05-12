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
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute")
                    ]),
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string("Timeout in seconds (default 60)")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            requiresApproval: true
        ) { args in
            guard let command = args["command"]?.stringValue else {
                throw AskToolError.invalidArguments("'command' (string) is required")
            }
            let timeout = args["timeout"]?.intValue ?? 60

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
