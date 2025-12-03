# ARO-0022: HTTP Client

* Proposal: ARO-0022
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020

## Abstract

This proposal defines HTTP client capabilities for ARO applications using AsyncHTTPClient, enabling outgoing HTTP requests to external services.

## Motivation

Applications often need to consume external APIs. ARO needs:

1. **HTTP Requests**: Make GET, POST, PUT, DELETE, PATCH requests
2. **Response Handling**: Parse and process HTTP responses
3. **JSON Support**: Automatic JSON parsing for API responses

---

## Syntax

### 1. GET Requests

Use `<Request>` with `from` preposition for GET requests:

```aro
(* GET request *)
<Request> the <response> from the <url>.

(* With variable URL *)
<Create> the <api-url> with "https://api.example.com/users".
<Request> the <users> from the <api-url>.
```

### 2. POST Requests

Use `<Request>` with `to` preposition for POST requests:

```aro
(* POST request - body from context *)
<Request> the <result> to the <url> with <data>.

(* POST with JSON body *)
<Create> the <user-data> with { name: "Alice", email: "alice@example.com" }.
<Request> the <created-user> to the <api-url> with <user-data>.
```

### 3. Other HTTP Methods

Use `<Request>` with `via` preposition and method specifier:

```aro
(* PUT request *)
<Request> the <result> via PUT the <url> with <data>.

(* DELETE request *)
<Request> the <result> via DELETE the <url>.

(* PATCH request *)
<Request> the <result> via PATCH the <url> with <partial-data>.
```

---

## Response Data

The `<Request>` action automatically:
- Parses JSON responses into ARO maps/lists
- Returns raw string for non-JSON responses
- Binds response metadata to result variables

### Response Variables

After a request, these variables are available:

| Variable | Description |
|----------|-------------|
| `result` | Parsed response body (JSON as map/list, or string) |
| `result.statusCode` | HTTP status code (e.g., 200, 404) |
| `result.headers` | Response headers as map |
| `result.isSuccess` | Boolean: true if status 200-299 |

```aro
<Request> the <response> from "https://api.example.com/users".
<Extract> the <status> from the <response: statusCode>.
<Extract> the <users> from the <response>.
```

---

## Complete Example

```aro
(Fetch Weather: External API) {
    <Create> the <api-url> with "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true".
    <Request> the <weather> from the <api-url>.
    <Extract> the <temperature> from the <weather: current_weather temp>.
    <Return> an <OK: status> with <temperature>.
}

(Create User: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Request> the <created> to the <api-url> with <user-data>.
    <Return> a <Created: status> with <created>.
}
```

---

## Implementation Location

The HTTP client is implemented in:

- `Sources/ARORuntime/HTTP/Client/HTTPClient.swift` - AsyncHTTPClient wrapper
- `Sources/ARORuntime/Actions/BuiltIn/RequestAction.swift` - Request action implementation

Examples:
- `Examples/HTTPClient/` - HTTP client example

---

## Implementation Notes

- Uses AsyncHTTPClient for non-blocking requests
- Supports timeout configuration (default 30 seconds)
- Automatically parses JSON responses
- Thread-safe for concurrent requests
- Available on macOS, Linux (not Windows)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 2.0 | 2024-12 | Simplified: removed api definitions, use `<Request>` action with prepositions |
