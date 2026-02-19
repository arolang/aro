# ARO-0043: Sink Syntax

* Proposal: ARO-0043
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004

## Abstract

This proposal defines sink syntax—the ability to place expressions directly in the result position of ARO statements. Sink syntax enables concise, readable statements for actions that consume values without binding new variables, particularly useful for logging, sending, and notification actions.

---

## 1. Motivation

### 1.1 Standard vs Sink Syntax

Standard ARO syntax requires a variable binding in the result position:

```aro
(* Standard syntax - binds a variable *)
Create the <message> with "Hello, World!".
Log the <message> to the <console>.
```

Sink syntax allows expressions directly in the result position:

```aro
(* Sink syntax - direct expression, no binding *)
Log "Hello, World!" to the <console>.
```

### 1.2 Use Cases

Sink syntax is ideal for:
- Logging messages without intermediate variables
- Sending data without needing to reference it later
- Notifications and alerts
- Any action where the value is "sunk" (consumed without producing a binding)

---

## 2. Syntax

### 2.1 General Form

```aro
Action expression preposition <object>.
```

Where `expression` can be:
- String literal: `"message"`
- Number literal: `42`, `3.14`
- Boolean literal: `true`, `false`
- Variable reference: `<variable>`
- Qualified variable: `<variable: property>`
- Object literal: `{ key: "value" }`
- Array literal: `[1, 2, 3]`

### 2.2 Omitting "the"

With sink syntax, the article `the` is omitted before the expression:

```aro
(* Standard syntax - with "the" *)
Log the <message> to the <console>.

(* Sink syntax - without "the" *)
Log "message" to the <console>.
Log <message> to the <console>.
```

---

## 3. Examples

### 3.1 String Literals

```aro
(* Direct string logging *)
Log "Application starting..." to the <console>.
Log "Processing complete!" to the <console>.

(* With stderr *)
Log "Error: Connection failed" to the <console: error>.
```

### 3.2 Variable References

```aro
Create the <user> with { name: "Alice", role: "admin" }.

(* Log the entire variable *)
Log <user> to the <console>.

(* Log a property *)
Log <user: name> to the <console>.
```

### 3.3 Numeric Values

```aro
Compute the <count> from 42.
Log <count> to the <console>.

(* Direct number - less common but supported *)
Log 100 to the <console>.
```

### 3.4 Object Literals

```aro
Create the <status> with { code: 200, message: "OK" }.
Log <status> to the <console>.
```

### 3.5 Send Action

```aro
(* Send data to socket client *)
Send <response-data> to the <client>.

(* Send string directly *)
Send "Welcome to the server!" to the <client>.
```

### 3.6 Notify Action

```aro
(* Alert with message *)
Notify the <user> with "Your order has shipped!".
Alert the <admin> with "System health check failed".
```

---

## 4. Supported Actions

Sink syntax is particularly useful with these action types:

| Action | Role | Typical Usage |
|--------|------|---------------|
| `Log` | EXPORT | Logging values to console/stderr |
| `Send` | EXPORT | Sending data over sockets |
| `Notify` | EXPORT | User notifications |
| `Alert` | EXPORT | Admin/system alerts |
| `Signal` | EXPORT | System signals |

Other actions may support sink syntax where semantically meaningful.

---

## 5. Implementation

### 5.1 ValueSource Enum

The parser recognizes sink expressions via the `ValueSource` enum:

```swift
public enum ValueSource: Sendable {
    case none
    case literal(LiteralValue)
    case expression(any Expression)
    case sinkExpression(any Expression)  // Sink syntax
}
```

### 5.2 Detection

Sink syntax is detected when:
1. An expression appears in the result position
2. The expression is not preceded by `the`
3. The expression is not a simple variable binding

```swift
public var isSinkSyntax: Bool {
    if case .sinkExpression = self { return true }
    return false
}
```

### 5.3 Statement Description

The description format changes for sink syntax:

```swift
public var description: String {
    if case .sinkExpression(let expr) = valueSource {
        // Sink syntax: Log "message" to the <console>
        return "<\(action.verb)> \(expr) \(object.preposition) the <\(object.noun)>"
    } else {
        // Standard: Log the <message> to the <console>
        return "<\(action.verb)> the <\(result)> \(object.preposition) the <\(object.noun)>"
    }
}
```

---

## 6. Comparison

### 6.1 Standard vs Sink

| Aspect | Standard Syntax | Sink Syntax |
|--------|----------------|-------------|
| **Binding** | Creates variable binding | No binding |
| **Article** | Requires `the` | Omits `the` |
| **Use case** | Need to reference later | Fire-and-forget |
| **Verbosity** | More verbose | More concise |

### 6.2 When to Use Each

**Use Standard Syntax when:**
- You need to reference the value later
- You want to transform the value
- The value is reused multiple times

```aro
Create the <message> with "User " ++ <name> ++ " logged in".
Log the <message> to the <console>.
Send the <message> to the <admin-socket>.
```

**Use Sink Syntax when:**
- The value is used only once
- No binding is needed
- You want concise, readable code

```aro
Log "Starting server..." to the <console>.
Log "Server ready on port 8080" to the <console>.
```

---

## 7. Grammar Extension

```ebnf
aro_statement = "<" , action , ">" , result_clause , preposition , object_clause , "." ;

result_clause = standard_result | sink_expression ;

standard_result = "the" , "<" , identifier , [ ":" , qualifier ] , ">" ;

sink_expression = string_literal
                | number_literal
                | boolean_literal
                | variable_reference
                | object_literal
                | array_literal ;

variable_reference = "<" , identifier , [ ":" , qualifier ] , ">" ;
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Purpose** | Concise value consumption without binding |
| **Syntax** | `Action expression preposition <object>.` |
| **Article** | Omits `the` before expression |
| **Actions** | Log, Send, Notify, Alert, Signal |
| **Types** | Strings, numbers, variables, objects, arrays |

---

## References

- `Sources/AROParser/AST.swift` - ValueSource enum with sinkExpression case
- `Examples/SinkSyntax/` - Sink syntax examples
- ARO-0001: Language Fundamentals - Core syntax
- ARO-0004: Actions - Action definitions
