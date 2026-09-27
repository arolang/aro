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

    /// Timeout in milliseconds (default: 30000).
    ///
    /// When the child is still running after this many milliseconds it is
    /// terminated (SIGTERM, then SIGKILL after a grace period) and the action
    /// returns `exitCode: -1`. `0` — or any non-positive value — means *no
    /// timeout*: the action waits for the child however long it takes, which is
    /// the only honest setting for a command whose runtime cannot be guessed
    /// (a full build, a large `rsync`).
    public let timeout: Int

    /// Shell to use (default: /bin/sh)
    public let shell: String

    /// Whether to capture stderr in output (default: true)
    public let captureStderr: Bool

    /// The host's command interpreter, and the flag that makes it read a
    /// command from its argument.
    ///
    /// This file had no `#if os(Windows)` in it at all, so `Exec` on Windows
    /// tried to launch `/bin/sh` and failed at process creation with a
    /// Foundation error that named no ARO statement (GitLab #682).
    ///
    /// `cmd.exe` rather than PowerShell: it is the interpreter `%COMSPEC%`
    /// names, it is present on every Windows install, and `/c` takes the
    /// command as one string the way `sh -c` does. PowerShell's `-Command`
    /// re-parses its argument under different quoting rules, which would make
    /// the same ARO source mean two things on one platform.
    public static var defaultShell: String {
        #if os(Windows)
        ProcessInfo.processInfo.environment["COMSPEC"] ?? "C:\\Windows\\System32\\cmd.exe"
        #else
        "/bin/sh"
        #endif
    }

    /// The flag that hands `defaultShell` a command string.
    public static var shellCommandFlag: String {
        #if os(Windows)
        "/c"
        #else
        "-c"
        #endif
    }

    public init(
        command: String,
        argv: [String]? = nil,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Int = 30000,
        shell: String? = nil,
        captureStderr: Bool = true
    ) {
        self.command = command
        self.argv = argv
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.shell = shell ?? ExecConfig.defaultShell
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
///     exitCode: Int,      // Process exit code (-1 = timed out)
///     command: String     // Executed command
/// }
/// ```
///
/// ## Timeout
///
/// Every command is bounded by `timeout` milliseconds — 30 000 (30s) unless the
/// configuration object says otherwise. A command that outlives its timeout is
/// terminated and the action returns `exitCode: -1` with `error: true` and
/// whatever output the command produced before it was stopped. It does not
/// throw: `when <r: exitCode> is -1` and `<r: error>` guards are how a program
/// sees a timeout, exactly as `ExecResult` has always documented.
///
/// Termination escalates — SIGTERM first, then SIGKILL after a two-second
/// grace period — and is aimed at the child's *process group* when the child
/// leads one, so a shell command that backgrounded work
/// (`"server & sleep 100"`) does not leave the grandchildren running and
/// holding the output pipe open.
///
/// `timeout: 0` (or any non-positive value) disables the bound and waits for
/// the child indefinitely.
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
                    timeout: Self.timeoutMilliseconds(exprConfig["timeout"]),
                    shell: exprConfig["shell"] as? String,
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

    /// Reads a configuration object's `timeout` field, in milliseconds.
    ///
    /// An object literal can hand the number over as `Int`, as `Double`
    /// (`timeout: 1500.0`) or as a `String` when it came from interpolation. A
    /// timeout silently discarded because of its Swift type would be the same
    /// bug this enforcement exists to fix (GitLab #586), so every numeric
    /// spelling is accepted; anything else falls back to the 30s default.
    static func timeoutMilliseconds(_ raw: (any Sendable)?) -> Int {
        let fallback = 30000
        guard let raw else { return fallback }
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String, let parsed = Double(value) { return Int(parsed) }
        return fallback
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
            // Shell-free execution: no interpreter is involved, so arguments
            // reach the process exactly as written and metacharacters in them
            // are inert (GitLab #471). A name with a separator in it is a path
            // and is launched directly; a bare name needs a PATH search, and
            // the two platforms spell that differently.
            if executable.contains("/") || executable.contains("\\") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(argv.dropFirst())
            } else {
                #if os(Windows)
                // There is no `/usr/bin/env`. `ToolResolver` asks `where.exe`,
                // which is the same PATH search `env` performs and, like it,
                // interprets nothing — so arguments still reach the process
                // exactly as written (GitLab #682). Falling through to the
                // bare name lets Foundation report a missing executable, which
                // is a better error than a missing `env`.
                process.executableURL = URL(fileURLWithPath: ToolResolver.findTool(executable) ?? executable)
                process.arguments = Array(argv.dropFirst())
                #else
                // `env` performs the PATH lookup without interpreting any
                // argument (GitLab #471).
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = argv
                #endif
            }
        } else {
            process.executableURL = URL(fileURLWithPath: config.shell)
            process.arguments = [ExecConfig.shellCommandFlag, config.command]
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
        //
        // Chunked rather than readDataToEndOfFile(): on a timeout the reader may
        // never see EOF (a surviving grandchild can hold the write end open), and
        // whatever the command printed before it was killed is still worth
        // returning. The box's lock is what makes the partial read safe to take
        // while the reader thread may still be appending.
        //
        // Dedicated threads rather than DispatchQueue.global(): every thread here
        // blocks, and a run bounded by a deadline must not first queue for a
        // worker that other blocked work is holding.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readGroup = DispatchGroup()

        readGroup.enter()
        startThread(named: "aro.exec.stdout") {
            drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
            readGroup.leave()
        }
        readGroup.enter()
        startThread(named: "aro.exec.stderr") {
            drain(stderrPipe.fileHandleForReading, into: stderrBox)
            readGroup.leave()
        }

        // Bound the child by `config.timeout` milliseconds. A non-positive
        // timeout means "no timeout" and just waits.
        let exited = DispatchSemaphore(value: 0)
        startThread(named: "aro.exec.wait") {
            process.waitUntilExit()
            exited.signal()
        }

        var timedOut = false
        if config.timeout > 0 {
            if exited.wait(timeout: .now() + .milliseconds(config.timeout)) == .timedOut {
                timedOut = true
                terminateTimedOutChild(process, exited: exited)
            }
        } else {
            exited.wait()
        }

        // Wait for pipe reads to complete. Unbounded on the normal path — the
        // reads end at EOF once the child's descriptors are closed. Bounded once
        // we have killed the child, because a grandchild that inherited the pipe
        // and outlived the group kill would otherwise hang the feature set, which
        // is precisely what the timeout exists to prevent.
        if timedOut {
            _ = readGroup.wait(timeout: .now() + orphanedPipeGrace)
        } else {
            readGroup.wait()
        }

        let stdout = String(data: stdoutBox.take(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrBox.take(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // -1 is the code `ExecResult` reserves for a timeout. Returning it rather
        // than throwing keeps `when <r: exitCode> is …` guards working (GitLab #586).
        // `terminationStatus` is only read on the path where the semaphore proved
        // the process exited — reading it on a live process traps.
        let exitCode = timedOut ? -1 : Int(process.terminationStatus)
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

        let message: String
        if timedOut {
            message = "Command timed out after \(config.timeout)ms"
        } else if hasError {
            message = "Command failed with exit code \(exitCode)"
        } else {
            message = "Command executed successfully"
        }

        return ExecResult(
            error: hasError,
            message: message,
            output: output,
            exitCode: exitCode,
            command: config.command
        )
    }
}

// MARK: - Process Termination (GitLab #586)

/// How long a timed-out child gets to honour SIGTERM before SIGKILL follows.
///
/// The same escalation, and the same two seconds, the runtime already uses for
/// REPL kernels, LSP servers and MCP subprocesses.
private let terminationGrace: TimeInterval = 2.0

/// How long to wait for the output pipes after a kill before giving up on them.
private let orphanedPipeGrace: DispatchTimeInterval = .seconds(2)

/// Terminates a timed-out child: SIGTERM, then SIGKILL if it is still there.
///
/// The signal goes to the child's *process group* when the child leads one — a
/// shell command can background work (`"server & sleep 100"`), and signalling
/// only `/bin/sh` leaves those grandchildren running and holding the output pipe
/// open. The group is only signalled when `getpgid(child) == child` and that
/// group is not our own, so a runtime whose `Process` did not put the child in a
/// fresh group can never end up signalling `aro` itself.
///
/// `exited` is signalled by the waiter thread when the child is reaped; it is
/// what the grace period waits on, so no polling of `isRunning` is involved.
private func terminateTimedOutChild(_ process: Process, exited: DispatchSemaphore) {
    let pid = process.processIdentifier
    let group = childProcessGroup(of: pid)

    if let group { kill(-group, SIGTERM) }
    // Also signal the child directly: with no group of its own that is the only
    // reachable target, and with one it costs nothing.
    kill(pid, SIGTERM)

    if exited.wait(timeout: .now() + .milliseconds(Int(terminationGrace * 1000))) == .success {
        // The child honoured SIGTERM. Backgrounded grandchildren may not have.
        if let group { kill(-group, SIGKILL) }
        return
    }

    if let group { kill(-group, SIGKILL) }
    kill(pid, SIGKILL)
    // SIGKILL cannot be caught, so this returns almost at once; the bound is
    // there only so an unreapable child cannot hang the feature set.
    _ = exited.wait(timeout: .now() + .milliseconds(Int(terminationGrace * 1000)))
}

/// The child's process group id, when the child leads a group of its own that is
/// distinct from the runtime's. `nil` means "no group is safe to signal".
private func childProcessGroup(of pid: pid_t) -> pid_t? {
    let group = getpgid(pid)
    guard group == pid, group != getpgrp() else { return nil }
    return group
}

/// Reads a handle to EOF in chunks, appending to a lock-protected box so a
/// partial read stays safe to take while the reader is still running.
private func drain(_ handle: FileHandle, into box: DataBox) {
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { return }
        box.append(chunk)
    }
}

/// Lock-protected accumulator for a pipe's bytes.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Runs `body` on a thread of its own.
///
/// Every thread this file starts spends its life blocked — on a pipe read or on
/// the child. Handing that to `DispatchQueue.global()` makes the timeout depend
/// on a free worker in a pool that other blocked work can exhaust; under a
/// parallel test run it did exactly that, and the deadline never fired.
private func startThread(named name: String, _ body: @escaping @Sendable () -> Void) {
    let thread = Thread(block: body)
    thread.name = name
    thread.stackSize = 512 * 1024
    thread.start()
}

// MARK: - Action Error Extension

extension ActionError {
    static func missingRequiredField(_ field: String) -> ActionError {
        return .runtimeError("Missing required field: \(field)")
    }
}
