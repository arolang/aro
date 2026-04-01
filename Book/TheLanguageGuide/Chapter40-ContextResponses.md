# Chapter 40: Context-Aware Response Formatting

ARO automatically formats responses and log output based on the execution context. The same code produces different output formats depending on how it's invoked.

## Execution Contexts

ARO recognizes three execution contexts:

| Context | Trigger | Output Format |
|---------|---------|---------------|
| **Human** | `aro run`, CLI execution | Readable text |
| **Machine** | HTTP API, events | JSON/structured data |
| **Developer** | `aro test`, debug mode | Detailed diagnostics |

<div style="text-align: center; margin: 2em 0;">
<svg width="560" height="180" viewBox="0 0 560 180" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Input: Return statement (indigo) -->
  <rect x="10" y="65" width="175" height="50" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="97" y="85" text-anchor="middle" font-size="10" fill="#4338ca" font-weight="bold">Return an &lt;OK: status&gt;</text>
  <text x="97" y="102" text-anchor="middle" font-size="9" fill="#4338ca">with &lt;data&gt;</text>

  <!-- Arrow to JSON (top) -->
  <line x1="185" y1="78" x2="240" y2="40" stroke="#1f2937" stroke-width="2"/>
  <polygon points="240,40 232,48 242,52" fill="#1f2937"/>
  <text x="195" y="50" text-anchor="start" font-size="8" fill="#374151">Accept: application/json</text>

  <!-- Arrow to HTML (middle) -->
  <line x1="185" y1="90" x2="240" y2="90" stroke="#1f2937" stroke-width="2"/>
  <polygon points="240,90 230,85 230,95" fill="#1f2937"/>
  <text x="187" y="84" text-anchor="start" font-size="8" fill="#374151">Accept: text/html</text>

  <!-- Arrow to Developer (bottom) -->
  <line x1="185" y1="102" x2="240" y2="140" stroke="#1f2937" stroke-width="2"/>
  <polygon points="240,140 230,136 238,146" fill="#1f2937"/>
  <text x="187" y="130" text-anchor="start" font-size="8" fill="#374151">X-ARO-Context: developer</text>

  <!-- Machine format (dark) -->
  <rect x="242" y="10" width="155" height="46" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="319" y="28" text-anchor="middle" font-size="10" fill="#ffffff" font-weight="bold">Machine format</text>
  <text x="319" y="46" text-anchor="middle" font-size="8" fill="#ffffff">{"status":"ok",...}</text>

  <!-- Human format (green) -->
  <rect x="242" y="67" width="155" height="46" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="319" y="85" text-anchor="middle" font-size="10" fill="#166534" font-weight="bold">Human format</text>
  <text x="319" y="103" text-anchor="middle" font-size="8" fill="#166534">formatted table</text>

  <!-- Developer format (amber) -->
  <rect x="242" y="124" width="155" height="46" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="319" y="142" text-anchor="middle" font-size="10" fill="#92400e" font-weight="bold">Developer format</text>
  <text x="319" y="160" text-anchor="middle" font-size="8" fill="#92400e">verbose + metadata</text>
</svg>
</div>

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

*Next: Chapter 41 — Type System*
