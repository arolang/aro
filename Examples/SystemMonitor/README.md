# SystemMonitor Example

A comprehensive HTTP API demonstrating the `<Exec>` action (ARO-0010) with context-aware response formatting (ARO-0031).

## Features

- Execute system commands via HTTP API
- Context-aware formatting:
  - **HTTP requests**: JSON responses
  - **Console**: Formatted plaintext
  - **Debug mode**: Diagnostic tables

## Running

```bash
# Run with interpreter
aro run ./Examples/SystemMonitor

# Server starts at http://localhost:8080
```

## API Endpoints

### Execute Command
```bash
# Execute any command
curl "http://localhost:8080/exec?cmd=ls%20-la"
```

Response (JSON):
```json
{
  "status": "OK",
  "data": {
    "result": {
      "error": false,
      "message": "Command executed successfully",
      "output": "total 48\ndrwxr-xr-x  12 user  staff   384 Dec 23 10:00 .\n...",
      "exitCode": 0,
      "command": "ls -la"
    }
  }
}
```

### List Directory
```bash
curl "http://localhost:8080/list?path=/tmp"
```

### Check Disk Usage
```bash
curl "http://localhost:8080/disk"
```

### List Processes
```bash
curl "http://localhost:8080/processes"
```

## Context-Aware Output

The same code produces different output based on context:

**HTTP API (JSON)**:
```json
{"error":false,"message":"Command executed successfully","output":"...","exitCode":0}
```

**Console (Plaintext)**:
```
[OK] Command executed successfully
  error: false
  exitCode: 0
  output:
    total 48
    drwxr-xr-x  12 user  staff   384 Dec 23 10:00 .
    ...
```

**Debug Mode (Table)**:
```
┌──────────────────────────────────────────────────────────────┐
│ Response<OK>                                                 │
├────────────────┬─────────────────────────────────────────────┤
│ error          │ Boolean(false)                              │
│ exitCode       │ Int(0)                                      │
│ message        │ String("Command executed successfully")     │
│ output         │ String[148 chars]                           │
└────────────────┴─────────────────────────────────────────────┘
```
