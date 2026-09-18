# DirectoryLister Example

Demonstrates the `<Exec>` action from ARO-0010 for executing system commands.

## Features

- Execute shell commands on the host system
- Structured result object with `error`, `message`, `output`, `exitCode`
- Context-aware output formatting (ARO-0031)

## Running

```bash
# Run with interpreter
aro run ./Examples/DirectoryLister

# Build native binary
aro build ./Examples/DirectoryLister --release
./Examples/DirectoryLister/DirectoryLister
```

## Result Format

The `<Exec>` action returns:

```typescript
{
    error: Boolean,     // true if command failed
    message: String,    // Human-readable status
    output: String,     // Command stdout/stderr
    exitCode: Int,      // Process exit code (0 = success)
    command: String     // The executed command
}
```

## Context-Aware Output

- **Console**: Plaintext with formatted output block
- **HTTP API**: JSON response with structured data
- **Debug mode**: Diagnostic table with type annotations
