# ARO-0031: Context-Aware Response Formatting

* Proposal: ARO-0031
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal defines context-aware response formatting in ARO. The runtime automatically adapts output format based on execution context—producing JSON for HTTP APIs, readable text for CLI users, and diagnostic tables for developers.

## Motivation

ARO applications run in different contexts with different output needs:

1. **HTTP API responses** need JSON for machine consumption
2. **CLI execution** (`aro run`) needs readable output for humans
3. **Debug mode** (`--debug`) needs detailed diagnostic information

Without context-aware formatting, developers would need to manually format output for each context:

```aro
(* Without context-aware formatting - manual formatting everywhere *)
<Create> the <json-output> with { status: <status>, data: <data> }.
<Return> an <OK: status> with <json-output>.
```

With context-aware formatting, the runtime handles adaptation:

```aro
(* With context-aware formatting - runtime adapts automatically *)
<Return> an <OK: status> with <data>.
```

---

## 1. Output Contexts

### 1.1 Context Types

| Context | Trigger | Format | Use Case |
|---------|---------|--------|----------|
| `machine` | HTTP request | JSON | API responses, programmatic access |
| `human` | `aro run` | Readable text | Terminal users, scripts |
| `developer` | `--debug` flag | Diagnostic table | Debugging, testing |

### 1.2 Context Detection

The runtime detects context based on execution environment:

```
HTTP Request → machine context
CLI without --debug → human context
CLI with --debug → developer context
```

---

## 2. Machine Context (JSON)

### 2.1 Format

Machine context produces JSON output suitable for API responses:

```json
{
  "status": 200,
  "reason": "OK",
  "data": {
    "user": {
      "id": "123",
      "name": "Alice"
    }
  }
}
```

### 2.2 Characteristics

- **Structured**: Valid JSON object
- **Complete**: Includes status, reason, and data
- **Sorted keys**: Consistent key ordering for reproducibility
- **Type-preserving**: Numbers stay numbers, booleans stay booleans

### 2.3 HTTP Integration

HTTP responses automatically use machine context:

```aro
(getUser: User API) {
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

Response:
```json
{"data":{"user":{"id":"123","name":"Alice"}},"reason":"user","status":200}
```

---

## 3. Human Context (Readable Text)

### 3.1 Format

Human context produces readable, scannable output:

```
[200] user
  user.id: 123
  user.name: Alice
```

### 3.2 Characteristics

- **Status line**: `[status_code] reason`
- **Dot notation**: Nested fields shown as `parent.child`
- **Indentation**: Two spaces for data fields
- **Sorted keys**: Alphabetical ordering
- **Simplified arrays**: Comma-separated values

### 3.3 Examples

**Simple response:**
```
[200] OK
  message: Success
```

**Nested data:**
```
[200] user
  user.address.city: New York
  user.address.zip: 10001
  user.name: Alice
```

**Array values:**
```
[200] users
  users: Alice, Bob, Carol
```

---

## 4. Developer Context (Diagnostic Table)

### 4.1 Format

Developer context produces a bordered table with type information:

```
┌──────────────────────────────────────────┐
│ Response<200>                            │
├────────────────┬─────────────────────────┤
│ reason         │ String("user")          │
│ user.id        │ String("123")           │
│ user.name      │ String("Alice")         │
└────────────────┴─────────────────────────┘
```

### 4.2 Characteristics

- **Bordered table**: Unicode box-drawing characters
- **Header**: `Response<status_code>`
- **Type annotations**: Each value shows its type
- **Flattened keys**: Nested values use dot notation
- **Sorted**: Alphabetical key ordering

### 4.3 Type Annotations

| Type | Format |
|------|--------|
| String | `String("value")` |
| Integer | `Int(42)` |
| Double | `Double(3.14)` |
| Boolean | `Bool(true)` |
| Dictionary | `Dict { key: Type(value) }` |
| Array | `[Type(v1), Type(v2)]` |
| Response | `Response<status>` |

### 4.4 Activation

Developer context is activated with the `--debug` flag:

```bash
aro run ./MyApp --debug
```

---

## 5. Log Action Integration

The Log action respects output context for console output:

### 5.1 Basic Logging

```aro
<Log> "Server started" to the <console>.
```

| Context | Output |
|---------|--------|
| machine | `"Server started"` |
| human | `Server started` |
| developer | `String("Server started")` |

### 5.2 Structured Data Logging

```aro
<Log> <user> to the <console>.
```

| Context | Output |
|---------|--------|
| machine | `{"id":"123","name":"Alice"}` |
| human | `id: 123`<br>`name: Alice` |
| developer | `Dict { id: String("123"), name: String("Alice") }` |

---

## 6. Error Message Formatting

Error messages also adapt to context:

### 6.1 Machine Context

```json
{
  "error": "Cannot retrieve the user from the user-repository where id = 999",
  "status": 404
}
```

### 6.2 Human Context

```
[404] Cannot retrieve the user from the user-repository where id = 999
```

### 6.3 Developer Context

```
┌──────────────────────────────────────────────────────────────────┐
│ Response<404>                                                     │
├────────────────┬─────────────────────────────────────────────────┤
│ error          │ String("Cannot retrieve the user...")           │
└────────────────┴─────────────────────────────────────────────────┘
```

---

## 7. Implementation

### 7.1 OutputContext Enum

```swift
public enum OutputContext: String, Sendable {
    case machine    // JSON for APIs
    case human      // Readable text for CLI
    case developer  // Diagnostic tables for debugging
}
```

### 7.2 ResponseFormatter

```swift
public struct ResponseFormatter: Sendable {
    public static func format(_ response: Response, for context: OutputContext) -> String
    public static func formatValue(_ value: any Sendable, for context: OutputContext) -> String
}
```

### 7.3 Response Extension

```swift
extension Response {
    public func format(for context: OutputContext) -> String
    public func toJSON() -> String           // machine context
    public func toFormattedString() -> String // human context
    public func toDiagnosticString() -> String // developer context
}
```

---

## 8. Best Practices

### 8.1 Let the Runtime Format

Don't manually construct JSON for responses:

```aro
(* Don't do this *)
<Create> the <json> with "{ \"status\": 200 }".
<Return> an <OK: status> with <json>.

(* Do this instead *)
<Return> an <OK: status> with <data>.
```

### 8.2 Use Structured Data

Return structured data and let the formatter handle presentation:

```aro
(* Good - structured data *)
<Return> an <OK: status> with { users: <users>, count: <count> }.

(* Avoid - pre-formatted strings *)
<Return> an <OK: status> with "Found 5 users".
```

### 8.3 Debug Mode for Development

Use `--debug` during development to see types and structure:

```bash
aro run ./MyApp --debug
```

---

## Summary

| Context | Output | Activation |
|---------|--------|------------|
| `machine` | JSON | HTTP request |
| `human` | Readable text | `aro run` |
| `developer` | Diagnostic table | `aro run --debug` |

Context-aware formatting ensures ARO applications produce appropriate output without manual formatting code.

---

## References

- `Sources/ARORuntime/Core/OutputContext.swift` - Context enum
- `Sources/ARORuntime/Core/ResponseFormatter.swift` - Formatting implementation
- `Examples/ContextAware/` - Example demonstrating all contexts
