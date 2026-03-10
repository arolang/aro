# Chapter 37: System Commands

ARO provides the `<Exec>` action for executing shell commands on the host system. This chapter covers command execution, result handling, and security considerations.

## Basic Execution

### Preferred Syntax

The preferred syntax places the command name in the object specifier:

```aro
(* Simple command *)
Exec the <result> for the <command: "uptime">.

(* Command with arguments *)
Exec the <result> for the <command: "ls"> with "-la".

(* Command with multiple arguments *)
Exec the <result> for the <command: "ls"> with ["-l", "-a", "-h"].
```

This syntax clearly separates the command from its arguments, making code more readable.

### Legacy Syntax

The legacy syntax with full command in the `with` clause is still supported:

```aro
Exec the <result> for the <command> with "ls -la".
Exec the <listing> for the <files> with "find . -name '*.txt'".
Exec the <status> for the <check> with "git status".
```

### Using Variables

Build commands dynamically with variables:

```aro
Create the <directory> with "/var/log".
Exec the <result> for the <command: "ls"> with "-la ${directory}".

Create the <pattern> with "*.aro".
Exec the <files> for the <command: "find"> with [". ", "-name", "${pattern}"].
```

## Result Object

Every `<Exec>` action returns a structured result object:

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="130" viewBox="0 0 520 130" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- ARO Feature Set (indigo) -->
  <rect x="10" y="30" width="150" height="60" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="85" y="52" text-anchor="middle" font-size="10" fill="#4338ca" font-weight="bold">ARO Feature Set</text>
  <text x="85" y="68" text-anchor="middle" font-size="8" fill="#4338ca">Exec the &lt;result&gt;</text>
  <text x="85" y="82" text-anchor="middle" font-size="8" fill="#4338ca">from &lt;shell: "ls -la"&gt;</text>

  <!-- Arrow: ARO → Shell (exec) -->
  <line x1="160" y1="52" x2="208" y2="52" stroke="#1f2937" stroke-width="2"/>
  <polygon points="208,52 198,47 198,57" fill="#1f2937"/>
  <text x="184" y="44" text-anchor="middle" font-size="8" fill="#374151">exec</text>

  <!-- System Shell (dark) -->
  <rect x="210" y="30" width="120" height="60" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="270" y="55" text-anchor="middle" font-size="10" fill="#ffffff" font-weight="bold">System Shell</text>
  <text x="270" y="72" text-anchor="middle" font-size="9" fill="#ffffff">fork / exec</text>

  <!-- Arrow: Shell → Output -->
  <line x1="330" y1="52" x2="378" y2="52" stroke="#1f2937" stroke-width="2"/>
  <polygon points="378,52 368,47 368,57" fill="#1f2937"/>
  <text x="354" y="44" text-anchor="middle" font-size="8" fill="#374151">output</text>

  <!-- Process Output (gray, dashed) -->
  <rect x="380" y="30" width="130" height="60" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="2" stroke-dasharray="4,2"/>
  <text x="445" y="55" text-anchor="middle" font-size="10" fill="#374151" font-weight="bold">Process Output</text>
  <text x="445" y="72" text-anchor="middle" font-size="9" fill="#374151">stdout capture</text>

  <!-- Arrow: Output → ARO (bound to result) -->
  <line x1="445" y1="90" x2="445" y2="115" stroke="#9ca3af" stroke-width="2" stroke-dasharray="4,2"/>
  <line x1="445" y1="115" x2="85" y2="115" stroke="#9ca3af" stroke-width="2" stroke-dasharray="4,2"/>
  <line x1="85" y1="115" x2="85" y2="91" stroke="#9ca3af" stroke-width="2" stroke-dasharray="4,2"/>
  <polygon points="85,91 80,101 90,101" fill="#9ca3af"/>
  <text x="265" y="128" text-anchor="middle" font-size="8" fill="#374151">bound to &lt;result&gt;</text>
</svg>
</div>

| Field | Type | Description |
|-------|------|-------------|
| `error` | Boolean | `true` if command failed (non-zero exit code) |
| `message` | String | Human-readable status message |
| `output` | String | Command stdout (or stderr if error) |
| `exitCode` | Int | Process exit code (0 = success, -1 = timeout) |
| `command` | String | The executed command string |

### Accessing Result Fields

```aro
Exec the <result> for the <command> with "whoami".

(* Access individual fields *)
Log <result.output> to the <console>.
Log <result.exitCode> to the <console>.

(* Check for errors *)
Log <result.message> to the <console> when <result.error> = true.
```

## Error Handling

### Checking for Errors

```aro
(Check Disk Space: System Monitor) {
    Exec the <result> for the <disk-check> with "df -h".

    Log <result.message> to the <console> when <result.error> = true.
    Return an <Error: status> with <result> when <result.error> = true.

    Return an <OK: status> with <result>.
}
```

### Handling Non-Zero Exit Codes

```aro
(Git Status: Version Control) {
    Exec the <result> for the <git> with "git status --porcelain".

    Log "Not a git repository" to the <console> when <result.exitCode> != 0.
    Return a <BadRequest: status> with { error: "Not a git repository" } when <result.exitCode> != 0.

    Return an <OK: status> with { message: "Working tree clean" } when <result.output> is empty.

    Return an <OK: status> with { changes: <result.output> }.
}
```

### Timeout Handling

Commands that exceed the timeout return with `exitCode: -1`:

```aro
Exec the <result> for the <long-task> with {
    command: "sleep 60",
    timeout: 5000
}.

Log "Command timed out" to the <console> when <result.exitCode> = -1.
```

## Configuration Options

For advanced control, use object syntax:

```aro
Exec the <result> on the <system> with {
    command: "npm install",
    workingDirectory: "/app",
    timeout: 60000,
    shell: "/bin/bash",
    environment: { NODE_ENV: "production" }
}.
```

### Available Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `command` | String | (required) | The shell command to execute |
| `workingDirectory` | String | current | Working directory for the command |
| `timeout` | Int | 30000 | Timeout in milliseconds |
| `shell` | String | /bin/sh | Shell to use for execution |
| `environment` | Object | (inherited) | Additional environment variables |
| `captureStderr` | Boolean | true | Include stderr in output |

## Context-Aware Output

Following ARO's context-aware response formatting (ARO-0031), `<Exec>` results display differently based on execution context.

### Console Output (Human Context)

```
command: ls -la
exitCode: 0
error: false
message: Command executed successfully
output:
  total 48
  drwxr-xr-x  12 user  staff   384 Dec 23 10:00 .
  -rw-r--r--   1 user  staff  1234 Dec 23 10:00 main.aro
```

### HTTP Response (Machine Context)

```json
{
    "status": "OK",
    "reason": "success",
    "data": {
        "result": {
            "error": false,
            "message": "Command executed successfully",
            "output": "total 48\ndrwxr-xr-x  12 user  staff...",
            "exitCode": 0,
            "command": "ls -la"
        }
    }
}
```

## Common Patterns

### Directory Listing

```aro
(Application-Start: Directory Lister) {
    Log "Directory Lister" to the <console>.
    Exec the <listing> for the <command> with "ls -la".
    Return an <OK: status> for the <listing>.
}
```

### System Information

```aro
(System Info: Status API) {
    Exec the <hostname> for the <command: "hostname">.
    Exec the <uptime> for the <command: "uptime">.
    Exec the <memory> for the <command: "free"> with "-h".

    Create the <info> with {
        hostname: <hostname.output>,
        uptime: <uptime.output>,
        memory: <memory.output>
    }.

    Return an <OK: status> with <info>.
}
```

### Build Pipeline

```aro
(Run Build: CI Pipeline) {
    Log "Installing dependencies..." to the <console>.
    Exec the <install> for the <npm> with {
        command: "npm install",
        workingDirectory: "./app",
        timeout: 120000
    }.

    Return an <Error: status> with <install> when <install.error> = true.

    Log "Running tests..." to the <console>.
    Exec the <test> for the <npm> with {
        command: "npm test",
        workingDirectory: "./app"
    }.

    Return an <Error: status> with <test> when <test.error> = true.

    Log "Building..." to the <console>.
    Exec the <build> for the <npm> with {
        command: "npm run build",
        workingDirectory: "./app"
    }.

    Return an <OK: status> with <build>.
}
```

### Health Checks

```aro
(Health Check: Monitoring) {
    Exec the <curl> for the <health> with {
        command: "curl -s http://localhost:8080/health",
        timeout: 5000
    }.

    Return a <ServiceUnavailable: status> with {
        service: "api",
        error: <curl.message>
    } when <curl.error> = true.

    Return an <OK: status> with { healthy: true }.
}
```

### Process Management

```aro
(List Processes: Admin API) {
    Exec the <processes> for the <list> with "ps aux | head -20".
    Return an <OK: status> with <processes>.
}

(Check Process: Admin API) {
    Extract the <name> from the <queryParameters: name>.
    Exec the <result> for the <check> with "pgrep -l ${name}".

    Return an <OK: status> with { running: false, process: <name> } when <result.error> = true.

    Return an <OK: status> with { running: true, process: <name>, pids: <result.output> }.
}
```

## Security Considerations

### Command Injection Prevention

Be cautious when constructing commands from user input:

```aro
(* DANGEROUS - user input directly in command *)
Exec the <result> for the <command> with "ls ${userInput}".

(* SAFER - validate input first *)
Validate the <path> for the <userInput> against "^[a-zA-Z0-9_/.-]+$".
Return a <BadRequest: status> with "Invalid path characters" when <path> is not <valid>.
Exec the <result> for the <command> with "ls ${path}".
```

### Best Practices

1. **Never trust user input** - Always validate and sanitize before using in commands
2. **Use allowlists** - Define allowed commands or patterns rather than blocking bad ones
3. **Limit permissions** - Run the ARO application with minimal required privileges
4. **Set timeouts** - Always specify reasonable timeouts to prevent hanging
5. **Log commands** - Keep audit logs of executed commands for security review

### Sandboxing (Future)

Future versions may support sandboxing options:

```aro
Exec the <result> for the <command> with {
    command: "npm install",
    sandbox: {
        network: false,
        filesystem: ["/app"],
        maxMemory: "512MB",
        maxTime: 60000
    }
}.
```

---

*Next: Chapter 38 — HTTP Client*
