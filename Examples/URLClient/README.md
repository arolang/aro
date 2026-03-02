# URLClient Example

This example demonstrates ARO-0052: Unified URL I/O, which extends the Read and Write actions to support URLs alongside file paths.

## Overview

With unified URL I/O:
- `Read the <data> from the <url: "...">` performs HTTP GET
- `Write the <data> to the <url: "...">` performs HTTP POST

This provides a consistent interface for both local file and remote HTTP operations.

## Features Demonstrated

1. **Simple GET Request** - Fetch JSON data from an API
2. **Custom Headers** - Use the `with` clause for authentication/headers
3. **POST Request** - Submit data to an API endpoint
4. **Auto-parsing** - Response is automatically parsed based on Content-Type

## Running

```bash
aro run ./Examples/URLClient
```

## Syntax

```aro
(* GET request *)
Read the <data> from the <url: "https://api.example.com/resource">.

(* GET with options *)
Read the <data> from the <url: "https://api.example.com/protected"> with {
    headers: {
        Authorization: "Bearer ${token}",
        Accept: "application/json"
    },
    timeout: 30
}.

(* POST request *)
Write the <payload> to the <url: "https://api.example.com/submit">.

(* POST with options *)
Write the <payload> to the <url: "https://api.example.com/submit"> with {
    headers: {
        Authorization: "Bearer ${token}",
        Content-Type: "application/json"
    },
    timeout: 60
}.
```

## Comparison with File I/O

| Operation | File I/O | URL I/O |
|-----------|----------|---------|
| Read | `Read <X> from <file: "path">` | `Read <X> from <url: "https://...">` |
| Write | `Write <X> to <file: "path">` | `Write <X> to <url: "https://...">` |

Both use the same syntax pattern, making it easy to switch between local and remote data sources.
