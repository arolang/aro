# Chapter 26: System Commands

ARO provides the `<Exec>` action for executing shell commands on the host system. This chapter covers command execution, result handling, and security considerations.

## Basic Execution

### Simple Commands

Execute shell commands using the `<Exec>` action:

```aro
<Exec> the <result> for the <command> with "ls -la".
<Exec> the <listing> for the <files> with "find . -name '*.txt'".
<Exec> the <status> for the <check> with "git status".
```

### Using Variables

Build commands dynamically with variables:

```aro
<Create> the <directory> with "/var/log".
<Exec> the <result> for the <listing> with "ls -la ${directory}".

<Create> the <pattern> with "*.aro".
<Exec> the <files> for the <search> with "find . -name '${pattern}'".
```

## Result Object

Every `<Exec>` action returns a structured result object:

| Field | Type | Description |
|-------|------|-------------|
| `error` | Boolean | `true` if command failed (non-zero exit code) |
| `message` | String | Human-readable status message |
| `output` | String | Command stdout (or stderr if error) |
| `exitCode` | Int | Process exit code (0 = success, -1 = timeout) |
| `command` | String | The executed command string |

### Accessing Result Fields

```aro
<Exec> the <result> for the <command> with "whoami".

(* Access individual fields *)
<Log> the <user: message> for the <console> with <result.output>.
<Log> the <exit: code> for the <console> with <result.exitCode>.

(* Check for errors *)
<Log> the <error: message> for the <console> with <result.message> when <result.error> = true.
```

## Error Handling

### Checking for Errors

```aro
(Check Disk Space: System Monitor) {
    <Exec> the <result> for the <disk-check> with "df -h".

    <Log> the <error> for the <console> with <result.message> when <result.error> = true.
    <Return> an <Error: status> with <result> when <result.error> = true.

    <Return> an <OK: status> with <result>.
}
```

### Handling Non-Zero Exit Codes

```aro
(Git Status: Version Control) {
    <Exec> the <result> for the <git> with "git status --porcelain".

    <Log> the <warning> for the <console> with "Not a git repository" when <result.exitCode> != 0.
    <Return> a <BadRequest: status> with { error: "Not a git repository" } when <result.exitCode> != 0.

    <Return> an <OK: status> with { message: "Working tree clean" } when <result.output> is empty.

    <Return> an <OK: status> with { changes: <result.output> }.
}
```

### Timeout Handling

Commands that exceed the timeout return with `exitCode: -1`:

```aro
<Exec> the <result> for the <long-task> with {
    command: "sleep 60",
    timeout: 5000
}.

<Log> the <timeout> for the <console> with "Command timed out" when <result.exitCode> = -1.
```

## Configuration Options

For advanced control, use object syntax:

```aro
<Exec> the <result> on the <system> with {
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
    <Log> the <startup: message> for the <console> with "Directory Lister".
    <Exec> the <listing> for the <command> with "ls -la".
    <Return> an <OK: status> for the <listing>.
}
```

### System Information

```aro
(System Info: Status API) {
    <Exec> the <hostname> for the <check> with "hostname".
    <Exec> the <uptime> for the <check> with "uptime".
    <Exec> the <memory> for the <check> with "free -h".

    <Create> the <info> with {
        hostname: <hostname.output>,
        uptime: <uptime.output>,
        memory: <memory.output>
    }.

    <Return> an <OK: status> with <info>.
}
```

### Build Pipeline

```aro
(Run Build: CI Pipeline) {
    <Log> the <step> for the <console> with "Installing dependencies...".
    <Exec> the <install> for the <npm> with {
        command: "npm install",
        workingDirectory: "./app",
        timeout: 120000
    }.

    <Return> an <Error: status> with <install> when <install.error> = true.

    <Log> the <step> for the <console> with "Running tests...".
    <Exec> the <test> for the <npm> with {
        command: "npm test",
        workingDirectory: "./app"
    }.

    <Return> an <Error: status> with <test> when <test.error> = true.

    <Log> the <step> for the <console> with "Building...".
    <Exec> the <build> for the <npm> with {
        command: "npm run build",
        workingDirectory: "./app"
    }.

    <Return> an <OK: status> with <build>.
}
```

### Health Checks

```aro
(Health Check: Monitoring) {
    <Exec> the <curl> for the <health> with {
        command: "curl -s http://localhost:8080/health",
        timeout: 5000
    }.

    <Return> a <ServiceUnavailable: status> with {
        service: "api",
        error: <curl.message>
    } when <curl.error> = true.

    <Return> an <OK: status> with { healthy: true }.
}
```

### Process Management

```aro
(List Processes: Admin API) {
    <Exec> the <processes> for the <list> with "ps aux | head -20".
    <Return> an <OK: status> with <processes>.
}

(Check Process: Admin API) {
    <Extract> the <name> from the <queryParameters: name>.
    <Exec> the <result> for the <check> with "pgrep -l ${name}".

    <Return> an <OK: status> with { running: false, process: <name> } when <result.error> = true.

    <Return> an <OK: status> with { running: true, process: <name>, pids: <result.output> }.
}
```

## Security Considerations

### Command Injection Prevention

Be cautious when constructing commands from user input:

```aro
(* DANGEROUS - user input directly in command *)
<Exec> the <result> for the <command> with "ls ${userInput}".

(* SAFER - validate input first *)
<Validate> the <path> for the <userInput> against "^[a-zA-Z0-9_/.-]+$".
<Return> a <BadRequest: status> with "Invalid path characters" when <path> is not <valid>.
<Exec> the <result> for the <command> with "ls ${path}".
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
<Exec> the <result> for the <command> with {
    command: "npm install",
    sandbox: {
        network: false,
        filesystem: ["/app"],
        maxMemory: "512MB",
        maxTime: 60000
    }
}.
```
