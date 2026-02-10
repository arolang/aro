// ============================================================
// ExecuteAction.swift
// ARO Runtime - System Command Execution Action (ARO-0033)
// ============================================================

import Foundation
import AROParser

// MARK: - Exec Result

/// Result of executing a system command
public struct ExecResult: Sendable, Codable, CustomStringConvertible {
    /// Whether the command failed (non-zero exit code or timeout)
    public let error: Bool

    /// Human-readable status message
    public let message: String

    /// Command output (stdout, or stderr if error)
    public let output: String

    /// Process exit code (0 = success, -1 = timeout)
    public let exitCode: Int

    /// The command that was executed
    public let command: String

    public init(
        error: Bool,
        message: String,
        output: String,
        exitCode: Int,
        command: String
    ) {
        self.error = error
        self.message = message
        self.output = output
        self.exitCode = exitCode
        self.command = command
    }

    public var description: String {
        // Format nicely for console output
        var lines: [String] = []
        lines.append("command: \(command)")
        lines.append("exitCode: \(exitCode)")
        lines.append("error: \(error)")
        if !message.isEmpty {
            lines.append("message: \(message)")
        }
        if !output.isEmpty {
            lines.append("output:")
            // Indent output lines
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append("  \(line)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Convert to dictionary for response formatting
    public func toDictionary() -> [String: any Sendable] {
        return [
            "error": error,
            "message": message,
            "output": output,
            "exitCode": exitCode,
            "command": command
        ]
    }
}

// MARK: - Exec Configuration

/// Configuration for command execution
public struct ExecConfig: Sendable {
    /// The shell command to execute
    public let command: String

    /// Working directory (default: current)
    public let workingDirectory: String?

    /// Additional environment variables
    public let environment: [String: String]?

    /// Timeout in milliseconds (default: 30000)
    public let timeout: Int

    /// Shell to use (default: /bin/sh)
    public let shell: String

    /// Whether to capture stderr in output (default: true)
    public let captureStderr: Bool

    public init(
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Int = 30000,
        shell: String = "/bin/sh",
        captureStderr: Bool = true
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.shell = shell
        self.captureStderr = captureStderr
    }
}

// MARK: - Execute Action

/// Executes shell commands on the host system
///
/// The Execute action runs shell commands and returns structured results with
/// error status, message, output, and exit code. Results are formatted
/// according to the execution context (JSON for HTTP, plaintext for console).
///
/// ## Syntax
/// ```aro
/// (* Command in object specifier - preferred syntax *)
/// <Execute> the <result> for the <command: "uptime">.
///
/// (* Command with arguments *)
/// <Execute> the <result> for the <command: "ls"> with "-la".
///
/// (* Command with multiple arguments *)
/// <Execute> the <result> for the <command: "ls"> with ["-l", "-a", "-h"].
///
/// (* Legacy: Full command in with clause *)
/// <Execute> the <result> for the <command> with "ls -la".
///
/// (* With configuration object *)
/// <Execute> the <result> on the <system> with {
///     command: "npm install",
///     workingDirectory: "/app"
/// }.
///
/// (* With timeout and environment *)
/// <Execute> the <result> for the <build> with {
///     command: "make release",
///     environment: { CC: "clang" },
///     timeout: 60000
/// }.
/// ```
///
/// ## Result Object
/// ```typescript
/// {
///     error: Boolean,     // true if command failed
///     message: String,    // Human-readable status
///     output: String,     // Command stdout/stderr
///     exitCode: Int,      // Process exit code
///     command: String     // Executed command
/// }
/// ```
///
/// ## Verbs
/// - `execute` (canonical)
/// - `exec` (synonym)
/// - `shell` (synonym)
/// - `run-command` (synonym)
public struct ExecuteAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["execute", "exec", "shell", "run-command"]
    public static let validPrepositions: Set<Preposition> = [.on, .with, .for]

    public init() {}

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)

        // Extract command configuration
        let config = try extractConfig(from: object, context: context)

        // Execute the command
        let execResult = await runCommand(config)

        // Return result as dictionary - FeatureSetExecutor will bind it
        // Individual fields (error, message, output, exitCode, command) are
        // accessible via dot notation: <listing.error>, <listing.output>, etc.
        return execResult.toDictionary()
    }

    // MARK: - Private Methods

    private func extractConfig(
        from object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> ExecConfig {
        // NEW SYNTAX: <Exec> the <result> for the <command: "uptime"> with "-args".
        // When object.base is "command" and specifiers contain the command name,
        // treat the "with" clause as arguments rather than the full command.
        if object.base == "command" && !object.specifiers.isEmpty {
            // The first specifier is the command name (e.g., "uptime" from <command: "uptime">)
            let commandName = object.specifiers[0]

            // Check for arguments in the "with" clause
            var arguments: [String] = []

            // Check _literal_ for string arguments
            if let literalArgs = context.resolveAny("_literal_") as? String, !literalArgs.isEmpty {
                arguments.append(literalArgs)
            }
            // Check _expression_ for string or array arguments
            else if let expr = context.resolveAny("_expression_") {
                if let stringArgs = expr as? String, !stringArgs.isEmpty {
                    arguments.append(stringArgs)
                } else if let arrayArgs = expr as? [String] {
                    arguments.append(contentsOf: arrayArgs)
                } else if let arrayAnySendable = expr as? [any Sendable] {
                    // Handle array of Any Sendable (convert to strings)
                    for arg in arrayAnySendable {
                        if let str = arg as? String {
                            arguments.append(str)
                        } else {
                            arguments.append(String(describing: arg))
                        }
                    }
                }
            }

            // Build the full command
            let fullCommand: String
            if arguments.isEmpty {
                fullCommand = commandName
            } else {
                fullCommand = commandName + " " + arguments.joined(separator: " ")
            }

            return ExecConfig(command: fullCommand)
        }

        // LEGACY SYNTAX: <Exec> the <result> for the <name> with "full command".
        // Priority 1: Check for literal string command (from "with" clause)
        if let literalCommand = context.resolveAny("_literal_") as? String, !literalCommand.isEmpty {
            return ExecConfig(command: literalCommand)
        }

        // Priority 2: Check _expression_ - can be a String or a dictionary
        if let expr = context.resolveAny("_expression_") {
            // If it's a string, use it as the command
            if let command = expr as? String, !command.isEmpty {
                return ExecConfig(command: command)
            }

            // If it's a dictionary with configuration
            if let exprConfig = expr as? [String: any Sendable],
               let command = exprConfig["command"] as? String {
                return ExecConfig(
                    command: command,
                    workingDirectory: exprConfig["workingDirectory"] as? String,
                    environment: exprConfig["environment"] as? [String: String],
                    timeout: (exprConfig["timeout"] as? Int) ?? 30000,
                    shell: (exprConfig["shell"] as? String) ?? "/bin/sh",
                    captureStderr: (exprConfig["captureStderr"] as? Bool) ?? true
                )
            }
        }

        // Priority 3: Check if the object.base is a variable containing a command
        if let command = context.resolveAny(object.base) as? String, !command.isEmpty {
            return ExecConfig(command: command)
        }

        // Priority 4: Check object specifiers for command
        for specifier in object.specifiers {
            if let command = context.resolveAny(specifier) as? String, !command.isEmpty {
                return ExecConfig(command: command)
            }
        }

        throw ActionError.missingRequiredField("command - use '<command: \"cmd\">' or 'with \"command\"' or 'with { command: \"...\" }'")
    }

    private func runCommand(_ config: ExecConfig) async -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.shell)
        process.arguments = ["-c", config.command]

        // Set working directory if specified
        if let workDir = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        // Set environment
        var environment = ProcessInfo.processInfo.environment
        if let extraEnv = config.environment {
            environment.merge(extraEnv) { _, new in new }
        }
        process.environment = environment

        // Set up pipes for output
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Start the process
        do {
            try process.run()
        } catch {
            return ExecResult(
                error: true,
                message: "Failed to start process: \(error.localizedDescription)",
                output: "",
                exitCode: -1,
                command: config.command
            )
        }

        // Wait with timeout
        let didTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return false
            }

            group.addTask {
                do {
                    try await Task.sleep(nanoseconds: UInt64(config.timeout) * 1_000_000)
                    if process.isRunning {
                        process.terminate()
                        return true
                    }
                } catch {
                    // Task cancelled, process finished
                }
                return false
            }

            // Wait for first result
            if let timedOut = await group.next() {
                group.cancelAll()
                return timedOut
            }
            return false
        }

        // Read output
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Determine result
        if didTimeout {
            return ExecResult(
                error: true,
                message: "Command timed out after \(config.timeout)ms",
                output: stdout.isEmpty ? stderr : stdout,
                exitCode: -1,
                command: config.command
            )
        }

        let exitCode = Int(process.terminationStatus)
        let hasError = exitCode != 0

        // Combine or select output based on error state
        let output: String
        if hasError && !stderr.isEmpty {
            output = config.captureStderr ? stderr : stdout
        } else if config.captureStderr && !stderr.isEmpty && !stdout.isEmpty {
            output = stdout + "\n" + stderr
        } else {
            output = stdout.isEmpty ? stderr : stdout
        }

        return ExecResult(
            error: hasError,
            message: hasError ? "Command failed with exit code \(exitCode)" : "Command executed successfully",
            output: output,
            exitCode: exitCode,
            command: config.command
        )
    }
}

// MARK: - Action Error Extension

extension ActionError {
    static func missingRequiredField(_ field: String) -> ActionError {
        return .runtimeError("Missing required field: \(field)")
    }
}
