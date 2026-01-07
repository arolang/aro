# ARO-0033: System Execute Action

* Proposal: ARO-0033
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0009, ARO-0031

## Abstract

This proposal introduces the `<Execute>` action for executing shell commands on the host system. The action provides a structured result object with consistent fields (`error`, `message`, `output`) and integrates with ARO's context-aware response formatting (ARO-0031) for optimal display across different execution contexts.

## Motivation

Many applications need to interact with the host operating system:

1. **DevOps Tooling**: Running deployment scripts, health checks, or system commands
2. **Build Pipelines**: Executing compilers, linters, or test runners
3. **System Administration**: Managing files, processes, or services
4. **Integration Tasks**: Calling external CLIs or legacy tools

Currently, ARO applications cannot execute arbitrary system commands. This proposal fills that gap while providing:

- Structured, predictable result format
- Context-aware output formatting (JSON for APIs, tables for console)
- Security considerations and sandboxing hooks

## Design

### Action Specification

| Property | Value |
|----------|-------|
| **Action** | Execute |
| **Verbs** | `execute` (canonical), `exec`, `shell`, `run-command` |
| **Role** | REQUEST (External → Internal) |
| **Prepositions** | `on`, `with`, `for` |

### Result Object Structure

Every `<Execute>` action returns a structured result object:

```typescript
{
    error: Boolean,     // true if command failed (non-zero exit code)
    message: String,    // Human-readable status message
    output: String,     // Command stdout (or stderr if error)
    exitCode: Int,      // Process exit code (0 = success)
    command: String     // The executed command (for logging/debugging)
}
```

### Syntax

```aro
(* Basic execution *)
<Execute> the <result> for the <command> with "ls -la".

(* Execute with working directory *)
<Execute> the <result> on the <system> with {
    command: "npm install",
    workingDirectory: "/app"
}.

(* Execute with environment variables *)
<Execute> the <result> for the <build> with {
    command: "make release",
    environment: { CC: "clang", CFLAGS: "-O2" }
}.

(* Execute with timeout *)
<Execute> the <result> for the <health-check> with {
    command: "curl -s http://localhost:8080/health",
    timeout: 5000
}.
```

### Full Options

```typescript
{
    command: String,              // Required: the shell command to execute
    workingDirectory?: String,    // Optional: working directory (default: current)
    environment?: Object,         // Optional: additional environment variables
    timeout?: Int,                // Optional: timeout in milliseconds (default: 30000)
    shell?: String,               // Optional: shell to use (default: /bin/sh)
    captureStderr?: Boolean       // Optional: include stderr in output (default: true)
}
```

## Context-Aware Output

Following ARO-0031, the `<Exec>` result formats differently based on execution context:

### Machine Context (HTTP/WebSocket)

```json
{
    "status": "OK",
    "reason": "success",
    "data": {
        "result": {
            "error": false,
            "message": "Command executed successfully",
            "output": "total 48\ndrwxr-xr-x  12 user  staff   384 Dec 23 10:00 .\ndrwxr-xr-x   5 user  staff   160 Dec 23 09:00 ..\n-rw-r--r--   1 user  staff  1234 Dec 23 10:00 main.aro",
            "exitCode": 0,
            "command": "ls -la"
        }
    }
}
```

### Human Context (Console/CLI)

```
[OK] Command executed successfully
  error: false
  exitCode: 0
  command: ls -la
  output:
    total 48
    drwxr-xr-x  12 user  staff   384 Dec 23 10:00 .
    drwxr-xr-x   5 user  staff   160 Dec 23 09:00 ..
    -rw-r--r--   1 user  staff  1234 Dec 23 10:00 main.aro
```

### Developer Context (Debug/Test)

```
┌──────────────────────────────────────────────────────────────┐
│ Response<OK>                                                 │
├────────────────┬─────────────────────────────────────────────┤
│ error          │ Boolean(false)                              │
│ exitCode       │ Int(0)                                      │
│ command        │ String("ls -la")                            │
│ message        │ String("Command executed successfully")     │
│ output         │ String[148 chars]                           │
└────────────────┴─────────────────────────────────────────────┘
```

## Complete Example

### Directory Listing Application

```aro
(* main.aro - Directory listing with context-aware output *)

(Application-Start: Directory Lister) {
    <Log> "Starting Directory Lister..." to the <console>.
    <Start> the <http-server> on port 8080.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(* openapi.yaml defines: GET /list -> listDirectory *)

(listDirectory: Directory API) {
    (* Extract optional path parameter, default to current directory *)
    <Extract> the <path> from the <queryParameters: path>.
    <Compute> the <directory> for the <path> with { default: "." }.

    (* Build the ls command *)
    <Create> the <command> with "ls -la ${directory}".

    (* Execute the command *)
    <Execute> the <result> for the <listing> with <command>.

    (* Check for errors *)
    if <result: error> = true then {
        <Return> a <ServerError: status> with <result>.
    }

    (* Parse output into structured data for better formatting *)
    <Transform> the <files> from the <result: output> with {
        parser: "ls-la",
        format: "table"
    }.

    (* Return with context-aware formatting *)
    <Return> an <OK: status> with <files>.
}

(* Console-only version for CLI usage *)
(Application-Start: Quick List) {
    <Execute> the <result> for the <listing> with "ls -la".

    if <result: error> = true then {
        <Log> <result: message> to the <console>.
        <Return> an <Error: status> with <result>.
    }

    <Log> <result: output> to the <console>.
    <Return> an <OK: status> with <result>.
}
```

### Running the Example

**Console (Human Context):**

```bash
$ aro run ./DirectoryLister
[Application-Start] Starting Directory Lister...
[OK] startup
  result.error: false
  result.exitCode: 0
  result.output:
    total 48
    drwxr-xr-x  12 user  staff   384 Dec 23 10:00 .
    -rw-r--r--   1 user  staff  1234 Dec 23 10:00 main.aro
    -rw-r--r--   1 user  staff   567 Dec 23 10:00 openapi.yaml
```

**HTTP API (Machine Context):**

```bash
$ curl http://localhost:8080/list?path=/tmp
{
  "status": "OK",
  "reason": "success",
  "data": {
    "files": [
      {"permissions": "drwxrwxrwt", "links": 12, "owner": "root", "group": "wheel", "size": 384, "date": "Dec 23 10:00", "name": "."},
      {"permissions": "-rw-r--r--", "links": 1, "owner": "user", "group": "staff", "size": 0, "date": "Dec 23 09:30", "name": "temp.txt"}
    ]
  }
}
```

**WebSocket (Machine Context):**

```json
{"type":"exec_result","data":{"error":false,"message":"Command executed successfully","output":"total 48\n...","exitCode":0}}
```

## Error Handling

When a command fails, the result object captures the error state:

```aro
(checkDiskSpace: System Monitor) {
    <Execute> the <result> for the <disk-check> with "df -h /nonexistent".

    (* result.error will be true, result.output contains stderr *)
    if <result: error> = true then {
        <Log> "Disk check failed: ${result.message}" to the <console>.
        <Return> a <Warning: status> with <result>.
    }

    <Return> an <OK: status> with <result>.
}
```

**Error Result Structure:**

```typescript
{
    error: true,
    message: "Command failed with exit code 1",
    output: "df: /nonexistent: No such file or directory",
    exitCode: 1,
    command: "df -h /nonexistent"
}
```

## Implementation

### Swift Action Implementation

```swift
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
        // Extract command configuration
        let config = try extractConfig(from: object, context: context)

        // Execute the command
        let execResult = try await runCommand(config)

        // Bind result to context
        context.bind(result.identifier, value: execResult)

        return execResult
    }

    private func runCommand(_ config: ExecConfig) async throws -> ExecResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.shell)
        process.arguments = ["-c", config.command]

        if let workDir = config.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }

        var environment = ProcessInfo.processInfo.environment
        if let extraEnv = config.environment {
            environment.merge(extraEnv) { _, new in new }
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        // Handle timeout
        let didTimeout = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(config.timeout) * 1_000_000)
                if process.isRunning {
                    process.terminate()
                    return true
                }
                return false
            }
            return await group.first { $0 } ?? false
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        let exitCode = Int(process.terminationStatus)
        let hasError = exitCode != 0 || didTimeout

        return ExecResult(
            error: hasError,
            message: didTimeout ? "Command timed out" :
                     hasError ? "Command failed with exit code \(exitCode)" :
                     "Command executed successfully",
            output: hasError && !errorOutput.isEmpty ? errorOutput : output,
            exitCode: didTimeout ? -1 : exitCode,
            command: config.command
        )
    }
}

public struct ExecResult: Sendable, Codable {
    public let error: Bool
    public let message: String
    public let output: String
    public let exitCode: Int
    public let command: String
}

public struct ExecConfig: Sendable {
    public let command: String
    public let workingDirectory: String?
    public let environment: [String: String]?
    public let timeout: Int
    public let shell: String

    public init(
        command: String,
        workingDirectory: String? = nil,
        environment: [String: String]? = nil,
        timeout: Int = 30000,
        shell: String = "/bin/sh"
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeout = timeout
        self.shell = shell
    }
}
```

### Registration

```swift
// In ActionRegistry.registerBuiltIns()
register(ExecuteAction.self)
```

## Security Considerations

### 1. Command Injection Prevention

The `<Execute>` action should validate and sanitize input when commands are constructed from user data:

```aro
(* DANGEROUS - user input directly in command *)
<Execute> the <result> for the <command> with "ls ${userInput}".

(* SAFER - validate input first *)
<Validate> the <path> for the <userInput> against "^[a-zA-Z0-9_/.-]+$".
if <path> is not <valid> then {
    <Return> a <BadRequest: status> with "Invalid path characters".
}
<Execute> the <result> for the <command> with "ls ${path}".
```

### 2. Sandboxing (Future)

Future versions may support sandboxing options:

```aro
<Execute> the <result> for the <command> with {
    command: "npm install",
    sandbox: {
        network: false,
        filesystem: ["/app"],
        maxMemory: "512MB",
        maxTime: 60000
    }
}.
```

### 3. Audit Logging

All `<Execute>` commands are logged with:
- Timestamp
- Feature set name
- Command executed
- Exit code
- Execution duration

## Related Proposals

- ARO-0009: Action Implementations
- ARO-0031: Context-Aware Response Formatting
- ARO-0023: File System

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-12 | Initial specification |
