# ARO-0019: Standard Library

* Proposal: ARO-0019
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0006

## Abstract

This proposal defines the ARO Standard Library, providing common types and utilities available in all ARO programs. ARO uses dynamic typing with type inference from literal values.

## Motivation

A standard library provides:

1. **Consistency**: Common patterns across projects
2. **Productivity**: Ready-to-use utilities
3. **Quality**: Well-tested implementations
4. **Portability**: Works across platforms

---

## 1. Primitive Types

ARO supports five primitive types. Types are inferred from literal values.

### 1.1 Integer

Whole numbers without decimals.

```aro
(Calculate Total: Math Example) {
    <Create> the <quantity> with 42.
    <Create> the <price> with 100.
    <Compute> the <total> from the <quantity> with <price>.
    <Return> an <OK: status> with <total>.
}
```

### 1.2 Float

Decimal numbers for precision calculations.

```aro
(Calculate Tax: Financial Example) {
    <Create> the <subtotal> with 99.99.
    <Create> the <tax-rate> with 0.08.
    <Compute> the <tax> from the <subtotal> with <tax-rate>.
    <Return> an <OK: status> with <tax>.
}
```

### 1.3 String

Text values enclosed in double quotes.

```aro
(Greet User: String Example) {
    <Create> the <greeting> with "Hello, World!".
    <Create> the <name> with "Alice".
    <Log> the <message> for the <console> with <greeting>.
    <Return> an <OK: status> with <name>.
}
```

### 1.4 Boolean

Logical true/false values.

```aro
(Check Status: Boolean Example) {
    <Create> the <is-active> with true.
    <Create> the <is-verified> with false.
    <Validate> the <user: status> with <is-active>.
    <Return> an <OK: status> for the <validation>.
}
```

### 1.5 DateTime

Date and time values for temporal operations.

```aro
(Log Event: DateTime Example) {
    <Create> the <timestamp> with now.
    <Create> the <event-name> with "UserLogin".
    <Log> the <event: info> for the <console> with <timestamp>.
    <Return> an <OK: status> for the <event>.
}
```

---

## 2. Collections

### 2.1 List

Ordered collections of values.

```aro
(Process Users: List Example) {
    <Retrieve> the <users> from the <user-repository>.
    <Filter> the <active-users> from the <users> where status = "active".
    <Map> the <names> from the <active-users> with name.
    <Return> an <OK: status> with <names>.
}
```

### 2.2 Map (Dictionary)

Key-value associations.

```aro
(Build Response: Map Example) {
    <Extract> the <user-id> from the <request: id>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}
```

---

## 3. String Operations

Strings support common operations through actions.

```aro
(Process Text: String Operations) {
    <Extract> the <name> from the <request: name>.
    <Transform> the <upper-name> from the <name> with uppercase.
    <Validate> the <name: format> with pattern "^[A-Za-z]+$".
    <Return> an <OK: status> with <upper-name>.
}
```

---

## 4. Date and Time

DateTime operations for temporal logic.

```aro
(Schedule Event: DateTime Operations) {
    <Create> the <start-time> with now.
    <Compute> the <end-time> from the <start-time> with "1 hour".
    <Log> the <schedule: info> for the <console> with <start-time>.
    <Return> an <OK: status> for the <schedule>.
}
```

---

## 5. Math Operations

Mathematical computations via the `<Compute>` action.

```aro
(Calculate Statistics: Math Example) {
    <Retrieve> the <values> from the <data-source>.
    <Reduce> the <sum: Integer> from the <values> with sum().
    <Reduce> the <average: Float> from the <values> with avg().
    <Reduce> the <count: Integer> from the <values> with count().
    <Return> an <OK: status> with <average>.
}
```

---

## 6. JSON Operations

JSON is handled automatically by the runtime for HTTP requests and responses.

```aro
(Parse Request: JSON Example) {
    <Extract> the <data> from the <request: body>.
    <Extract> the <name> from the <data: name>.
    <Extract> the <email> from the <data: email>.
    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}
```

---

## 7. Type Summary

| Type | Literal Example | Description |
|------|-----------------|-------------|
| Integer | `42`, `-10`, `0` | Whole numbers |
| Float | `3.14`, `0.5`, `-2.7` | Decimal numbers |
| String | `"Hello"`, `"World"` | Text values |
| Boolean | `true`, `false` | Logical values |
| DateTime | `now` | Current timestamp |
| List | (from actions) | Ordered collections |
| Map | (from actions) | Key-value pairs |

---

## Implementation Notes

ARO uses dynamic typing with type inference. The Swift runtime maps ARO values to Swift types:

| ARO Type | Swift Type |
|----------|------------|
| Integer | `Int` |
| Float | `Double` |
| String | `String` |
| Boolean | `Bool` |
| DateTime | `Date` |
| List | `[any Sendable]` |
| Map | `[String: any Sendable]` |

---

## Implementation Location

Primitive types are handled throughout the runtime:

- `Sources/ARORuntime/Actions/BuiltIn/OwnActions.swift` - CreateAction, ComputeAction
- `Sources/ARORuntime/Actions/BuiltIn/QueryActions.swift` - MapAction, ReduceAction, FilterAction
- `Sources/ARORuntime/Core/ExecutionContext.swift` - Variable binding with type inference
- `Sources/AROParser/Lexer.swift` - Literal parsing (strings, numbers, booleans)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-01 | Initial specification |
| 1.1 | 2024-12 | Simplified to core primitives (Integer, Float, String, Boolean, DateTime), removed Result type, added ARO examples |
