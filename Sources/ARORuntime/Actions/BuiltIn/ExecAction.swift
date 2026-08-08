// ============================================================
// ExecuteAction.swift
// ARO Runtime - System Command Execution Action (ARO-0010)
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
    /// The shell command to execute, or — when `argv` is set — a display-only
    /// rendering of the argument vector.
    public let command: String

    /// The argument vector to execute directly, bypassing the shell.
    ///
    /// When non-nil, `argv[0]` is the executable (resolved through `PATH`) and the
    /// remaining elements are passed as literal arguments. No shell is involved, so
    /// no element can be interpreted as a metacharacter.
    ///
    /// When nil, `command` is handed to `shell -c`, which *does* interpret
    /// metacharacters — that is the point of the single-string form
    /// (`Exec the <r> for the <command: "ps aux | head">.`).
    public let argv: [String]?

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
        argv: [String]? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Int = 30000,
        shell: String = "/bin/sh",
        captureStderr: Bool = true
    ) {
        self.command = command
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.shell = shell
        self.captureStderr = captureStderr
    }

    /// Builds a shell-free config from an argument vector.
    ///
    /// - Parameter argv: `argv[0]` is the executable; the rest are literal arguments.
    public static func direct(
        argv: [String],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Int = 30000,
        captureStderr: Bool = true
    ) -> ExecConfig {
        ExecConfig(
            command: displayString(for: argv),
            argv: argv,
            workingDirectory: workingDirectory,
            environment: environment,
            timeout: timeout,
            captureStderr: captureStderr
        )
    }

    /// Renders an argv for humans, quoting any element that is not a plain token.
    ///
    /// Display only — this string is never executed.
    static func displayString(for argv: [String]) -> String {
        argv.map { element in
            let needsQuoting = element.isEmpty || element.contains(where: {
                !($0.isLetter || $0.isNumber || "-_./=:@+".contains($0))
            })
            guard needsQuoting else { return element }
            return "'" + element.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }.joined(separator: " ")
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
/// ```
///
/// ## Shell interpretation
///
/// There are two execution modes, and the difference matters for security:
///
/// - **With a `with` clause** the qualifier names an executable and the `with`
///   values are its arguments. They are passed as a literal argument vector with
///   **no shell**, so metacharacters in them are inert. A single string is split
///   on whitespace (`with "-l -a"` → two flags); use the array form for an
///   argument that must contain whitespace (`with ["-m", "two words"]`).
///   This is the form to use for anything derived from untrusted input.
///
/// - **Without a `with` clause** the qualifier is a full command line run through
///   `/bin/sh -c`, so pipes and redirection work:
///   `<Execute> the <result> for the <command: "ps aux | head -20">.`
///   Never build this string from untrusted input — it is shell-interpreted.
///
/// ```aro
/// (* Safe: the value is one argument, whatever it contains *)
/// <Execute> the <r> for the <command: "echo"> with <untrusted>.
///
/// (* Shell-interpreted: only for command lines you control *)
/// <Execute> the <r> for the <command: "ps aux | head -20">.
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
/// - `run` (synonym)
/// - `shell` (synonym)
public struct ExecuteAction: ActionImplementation, SynchronousAction {
    public static let role: ActionRole = .own
    public static let verbs: Set<String> = ["execute", "exec", "run", "shell"]
    public static let validPrepositions: Set<Preposition> = [.on, .with, .for]

    public init() {}

    public func executeSynchronously(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> any Sendable {
        try validatePreposition(object.preposition)
        let config = try extractConfig(from: object, context: context)
        return Self.runCommandSync(config).toDictionary()
    }

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        try validatePreposition(object.preposition)
        let config = try extractConfig(from: object, context: context)
        return await runCommand(config).toDictionary()
    }

    // MARK: - Private Methods

    private func extractConfig(
        from object: ObjectDescriptor,
        context: ExecutionContext
    ) throws -> ExecConfig {
        // NEW SYNTAX: <Exec> the <result> for the <command: "uptime"> with "-args".
        // When object.base is "command" and specifiers contain the command name,
        // treat the "with" clause as arguments rather than the full command.
        if object.base == "command", let commandName = object.specifiers.first {
            // Arguments from the "with" clause. These are passed as a literal argv,
            // never spliced into a shell string — otherwise a value like
            // "hello; rm -rf ." would execute as two commands (GitLab #471).
            var arguments: [String] = []
            var hasWithClause = false

            // A single string is whitespace-tokenised, so `with "-l -a"` still yields
            // two flags. Tokens are passed literally, so shell metacharacters in them
            // are inert. Use the array form for an argument containing spaces.
            if let literalArgs = context.resolveAny("_literal_") as? String, !literalArgs.isEmpty {
                hasWithClause = true
                arguments.append(contentsOf: Self.tokenize(literalArgs))
            }
            // Check _expression_ for string or array arguments
            else if let expr = context.resolveAny("_expression_") {
                if let stringArgs = expr as? String, !stringArgs.isEmpty {
                    hasWithClause = true
                    arguments.append(contentsOf: Self.tokenize(stringArgs))
                } else if let arrayArgs = expr as? [String] {
                    // Array elements are exact argv entries — never re-tokenised,
                    // so `["--message", "hello world"]` stays two arguments.
                    hasWithClause = true
                    arguments.append(contentsOf: arrayArgs)
                } else if let arrayAnySendable = expr as? [any Sendable] {
                    hasWithClause = true
                    for arg in arrayAnySendable {
                        if let str = arg as? String {
                            arguments.append(str)
                        } else {
                            arguments.append(String(describing: arg))
                        }
                    }
                }
            }

            // No `with` clause: the qualifier is a full command line, so keep the
            // shell so that pipes and redirection still work
            // (`<command: "ps aux | head -20">`).
            guard hasWithClause else {
                return ExecConfig(command: commandName)
            }

            // With a `with` clause the qualifier names an executable. Tokenise it too,
            // so `<command: "python3 -u"> with <script>` behaves sensibly.
            let argv = Self.tokenize(commandName) + arguments
            guard !argv.isEmpty else {
                throw ActionError.missingRequiredField(
                    "command - '<command: \"...\">' resolved to an empty executable name"
                )
            }
            return ExecConfig.direct(argv: argv)
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
        // Run the entire process synchronously to avoid cooperative thread pool
        // and GCD scheduling issues that cause intermittent hangs.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runCommandSync(config))
            }
        }
    }

    /// Fully synchronous process execution on a dedicated thread.
    /// Reads pipes concurrently with process execution to prevent buffer deadlocks.
    /// Test hook for the process-execution path, so argv construction and shell
    /// avoidance can be asserted without going through the full action pipeline.
    static func runCommandSyncForTesting(_ config: ExecConfig) -> ExecResult {
        runCommandSync(config)
    }

    /// Splits a string into argv tokens on whitespace.
    ///
    /// Deliberately does *not* honour quotes: tokens are handed to the process
    /// verbatim, so there is no quoting layer to get wrong. An argument that must
    /// contain whitespace is passed via the array form (`with ["-m", "two words"]`).
    static func tokenize(_ input: String) -> [String] {
        input.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func runCommandSync(_ config: ExecConfig) -> ExecResult {
        let process = Process()

        if let argv = config.argv, let executable = argv.first {
            // Shell-free execution: `env` performs the PATH lookup without
            // interpreting any argument (GitLab #471). Arguments reach the process
            // exactly as written, so metacharacters in them are inert.
            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(argv.dropFirst())
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = argv
            }
        } else {
            process.executableURL = URL(fileURLWithPath: config.shell)
            process.arguments = ["-c", config.command]
        }

        if let workDir = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        var environment = ProcessInfo.processInfo.environment
        if let extraEnv = config.environment {
            environment.merge(extraEnv) { _, new in new }
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

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

        // Close parent's write ends so reads get EOF when child exits
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        // Read pipes concurrently to prevent buffer deadlock for large output.
        // nonisolated(unsafe) satisfies Swift 6 Sendable — DispatchGroup.wait()
        // provides the synchronization guarantee.
        nonisolated(unsafe) var stdoutData = Data()
        nonisolated(unsafe) var stderrData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        // Wait for process exit
        process.waitUntilExit()

        // Wait for pipe reads to complete
        readGroup.wait()

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
