# Chapter 34: Context-Aware Response Formatting

ARO automatically formats responses and log output based on the execution context. The same code produces different output formats depending on how it's invoked.

## Execution Contexts

ARO recognizes three execution contexts:

| Context | Trigger | Output Format |
|---------|---------|---------------|
| **Human** | `aro run`, CLI execution | Readable text |
| **Machine** | HTTP API, events | JSON/structured data |
| **Developer** | `aro test`, debug mode | Detailed diagnostics |

## How It Works

### Human Context (Default)

When you run ARO from the command line, output is formatted for readability:

```aro
(Application-Start: Example) {
    Log "Hello, World!" to the <console>.
    Return an <OK: status> for the <startup>.
}
```

Running with `aro run`:

```
[Application-Start] Hello, World!
```

### Machine Context

When code runs via HTTP request or event handler, output is structured data:

```json
{"level":"info","source":"Application-Start","message":"Hello, World!"}
```

### Developer Context

During test execution, output is displayed as a formatted table with type annotations:

```
+------------------------------------------+
| LOG [console] Application-Start          |
+------------------------------------------+
| message: String("Hello, World!")         |
+------------------------------------------+
```

## Automatic Detection

The runtime automatically detects context:

| Entry Point | Context |
|-------------|---------|
| `aro run` command | Human |
| `aro test` command | Developer |
| HTTP route handler | Machine |
| Event dispatch | Machine |
| `--debug` flag | Developer |

## Example: Same Code, Different Contexts

```aro
(getUser: User API) {
    Retrieve the <user> from the <user-repository> where id = <id>.
    Log "User retrieved" to the <console>.
    Return an <OK: status> with <user>.
}
```

### CLI Output (Human)

```
[getUser] User retrieved
[OK] success
  user.id: 123
  user.name: Alice
```

### HTTP Response (Machine)

```json
{
  "status": "OK",
  "reason": "success",
  "data": {
    "user": {"id": 123, "name": "Alice"}
  }
}
```

### Test Output (Developer)

```
+------------------------------------------+
| LOG [console] getUser                    |
+------------------------------------------+
| message: String("User retrieved")        |
+------------------------------------------+

+------------------------------------------+
| Response<OK>                             |
+----------------+-------------------------+
| reason         | String("success")       |
| user.id        | Int(123)                |
| user.name      | String("Alice")         |
+----------------+-------------------------+
```

## Benefits

1. **Write Once**: No need for separate formatting code
2. **Automatic Adaptation**: Output suits the consumer automatically
3. **Consistent Behavior**: Same logic, appropriate presentation
4. **Debug Friendly**: Rich diagnostics during development

## Integration with Actions

### Log Action

The `<Log>` action respects output context:

```aro
Log <value> to the <console>.
```

- **Human**: `[FeatureSetName] value`
- **Machine**: `{"level":"info","source":"FeatureSetName","message":"value"}`
- **Developer**: Formatted table with type annotations

### Return Action

The `<Return>` action sets the response, which is formatted based on context:

```aro
Return an <OK: status> with <result>.
```

---

*Next: Chapter 34 — Type System*
