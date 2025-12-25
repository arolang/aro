# Computations

Computations transform data within a feature set. The `<Compute>` action is the primary tool for deriving new values from existing data through built-in operations, arithmetic expressions, and custom plugins.

## Overview

The Compute action belongs to the **OWN** semantic role - it transforms data internally without external side effects.

### When to Use Compute vs Create

| Use Case | Action | Example |
|----------|--------|---------|
| Derive a value from another | Compute | `<Compute> the <length> from the <message>.` |
| Create a new object literal | Create | `<Create> the <user> with { name: "John" }.` |
| Apply a named operation | Compute | `<Compute> the <hash> from the <password>.` |
| Perform arithmetic | Compute | `<Compute> the <total> from <price> * <quantity>.` |

## Built-in Operations

The Compute action provides these built-in operations:

| Operation | Description | Input Types |
|-----------|-------------|-------------|
| `length` | Character/element count | String, Array, Dictionary |
| `count` | Alias for length | String, Array, Dictionary |
| `hash` | Compute hash value | Any (converts to String) |
| `uppercase` | Convert to uppercase | String |
| `lowercase` | Convert to lowercase | String |
| `identity` | Return input unchanged | Any |

### String Length

```aro
<Compute> the <length> from the <message>.
<Compute> the <count> from the <text>.
```

Returns the number of characters in a string:

```aro
(* message = "Hello, World!" *)
<Compute> the <length> from the <message>.
(* length = 13 *)
```

### Collection Size

The same operations work on arrays and dictionaries:

```aro
(* items = ["apple", "banana", "cherry"] *)
<Compute> the <count> from the <items>.
(* count = 3 *)

(* config = { host: "localhost", port: 8080 } *)
<Compute> the <length> from the <config>.
(* length = 2 *)
```

### Case Transformations

```aro
<Compute> the <upper: uppercase> from the <text>.
<Compute> the <lower: lowercase> from the <text>.
```

Example:

```aro
(* text = "Hello, World!" *)
<Compute> the <upper: uppercase> from the <text>.
(* upper = "HELLO, WORLD!" *)

<Compute> the <lower: lowercase> from the <text>.
(* lower = "hello, world!" *)
```

### Hashing

```aro
<Compute> the <hash> from the <password>.
```

Returns an integer hash value useful for comparisons and checksums.

## Naming Results

By default, the operation name becomes the variable name:

```aro
<Compute> the <length> from the <message>.  (* binds to 'length' *)
```

### The Qualifier-as-Name Syntax

When you need multiple results of the same operation, use a qualifier to specify the operation while the base becomes the variable name:

```aro
<Compute> the <variable: operation> from the <input>.
```

This syntax separates:
- **Base** (`variable`): The variable name to bind the result
- **Qualifier** (`operation`): The operation to perform

### Example: Comparing Two Lengths

```aro
(Compare Messages: String Analysis) {
    <Extract> the <greeting> from the <input: greeting> with "Hello, World!".
    <Extract> the <farewell> from the <input: farewell> with "Goodbye!".

    (* Compute lengths with distinct variable names *)
    <Compute> the <greeting-length: length> from the <greeting>.
    <Compute> the <farewell-length: length> from the <farewell>.

    (* Both values are available for comparison *)
    <Compare> the <greeting-length> against the <farewell-length>.

    <Return> an <OK: status> with {
        greeting: <greeting-length>,
        farewell: <farewell-length>
    }.
}
```

### Example: Multiple Transformations

```aro
(Text Formatting: String Operations) {
    <Extract> the <text> from the <input> with "Mixed Case Text".

    (* All three variables are distinct *)
    <Compute> the <original-length: length> from the <text>.
    <Compute> the <upper-case: uppercase> from the <text>.
    <Compute> the <lower-case: lowercase> from the <text>.

    <Return> an <OK: status> with {
        original: <text>,
        length: <original-length>,
        upper: <upper-case>,
        lower: <lower-case>
    }.
}
```

## Arithmetic Operations

Compute supports arithmetic expressions with these operators:

| Operator | Description | Example |
|----------|-------------|---------|
| `+` | Addition | `<price> + <tax>` |
| `-` | Subtraction | `<balance> - <withdrawal>` |
| `*` | Multiplication | `<quantity> * <price>` |
| `/` | Division | `<total> / <count>` |
| `%` | Modulo | `<value> % 2` |
| `++` | String concatenation | `<first> ++ <last>` |

### Arithmetic Examples

```aro
(Calculate Order: Shopping Cart) {
    <Extract> the <price> from the <item: price> with 100.
    <Extract> the <quantity> from the <item: quantity> with 3.

    (* Compute subtotal *)
    <Compute> the <subtotal> from <price> * <quantity>.

    (* Compute tax (8%) *)
    <Compute> the <tax> from <subtotal> * 0.08.

    (* Compute total *)
    <Compute> the <total> from <subtotal> + <tax>.

    <Return> an <OK: status> with {
        subtotal: <subtotal>,
        tax: <tax>,
        total: <total>
    }.
}
```

### String Concatenation

```aro
<Compute> the <full-name> from <first-name> ++ " " ++ <last-name>.
<Compute> the <greeting> from "Hello, " ++ <name> ++ "!".
```

## Extending via Plugins

The `ComputationService` protocol allows plugins to add custom computations.

### ComputationService Protocol

```swift
public protocol ComputationService: Sendable {
    func compute(named: String, input: Any) async throws -> any Sendable
}
```

### Creating a Custom Computation Plugin

1. Create a plugin file in your `plugins/` directory:

```swift
// plugins/HashService.swift
import Foundation
import CryptoKit

@_cdecl("aro_plugin_init")
public func pluginInit() -> UnsafePointer<CChar> {
    let metadata = """
    {
        "computations": ["sha256", "md5"]
    }
    """
    return UnsafePointer(strdup(metadata)!)
}

// Implementation of ComputationService
public struct CryptoComputationService: ComputationService {
    public func compute(named: String, input: Any) async throws -> any Sendable {
        guard let str = input as? String else {
            throw ComputationError.invalidInput
        }

        switch named.lowercased() {
        case "sha256":
            let digest = SHA256.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()

        case "md5":
            let digest = Insecure.MD5.hash(data: Data(str.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()

        default:
            throw ComputationError.unknownOperation(named)
        }
    }
}
```

2. Use in ARO code:

```aro
(Hash Password: Security) {
    <Extract> the <password> from the <input: password>.

    (* Use custom sha256 computation from plugin *)
    <Compute> the <password-hash: sha256> from the <password>.

    <Return> an <OK: status> with <password-hash>.
}
```

### Plugin Discovery

Plugins are automatically discovered from the `plugins/` directory relative to your application. See the Plugin chapter for full details on plugin development.

## Common Patterns

### Aggregation

```aro
<Retrieve> the <orders> from the <order-repository>.
<Compute> the <order-count: count> from the <orders>.
```

### Derived Values

```aro
<Extract> the <price> from the <product: price>.
<Extract> the <discount> from the <promotion: percent>.
<Compute> the <discount-amount> from <price> * (<discount> / 100).
<Compute> the <final-price> from <price> - <discount-amount>.
```

### Normalization

```aro
<Extract> the <email> from the <user: email>.
<Compute> the <normalized-email: lowercase> from the <email>.
```

### Chaining Computations

```aro
<Compute> the <base-price> from <quantity> * <unit-price>.
<Compute> the <discounted> from <base-price> * (1 - <discount>).
<Compute> the <with-tax> from <discounted> * (1 + <tax-rate>).
<Compute> the <final: identity> from <with-tax>.
```

## Related Actions

| Action | Purpose |
|--------|---------|
| Create | Create new objects from literals |
| Transform | Type conversions (string → int, etc.) |
| Validate | Check values against rules |
| Compare | Compare two values |

## See Also

- [Actions](Actions.md) - Overview of all actions
- [Variables](Variables.md) - Variable binding and scoping
- [Proposal ARO-0035](../Proposals/ARO-0035-qualifier-as-name.md) - Qualifier-as-name syntax specification
