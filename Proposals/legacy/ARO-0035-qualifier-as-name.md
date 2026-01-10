# ARO-0035: Qualifier-as-Name Result Syntax

* Proposal: ARO-0035
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0009

## Abstract

This proposal introduces a new syntax pattern for action result descriptors where the qualifier (specifier) determines the operation while the base identifier becomes the variable name. This enables computing multiple results of the same type with distinct variable names.

## Motivation

Currently, when computing values like string lengths, the result identifier serves double duty as both the variable name and the operation selector:

```aro
(* Problem: Both computations bind to the same variable 'length' *)
<Compute> the <length> from the <first-message>.   (* binds to 'length' *)
<Compute> the <length> from the <second-message>.  (* overwrites 'length'! *)
```

Since ARO variables are immutable within their scope, the second statement overwrites the first result. There's no way to preserve both lengths for later use.

### Use Cases

1. **Comparing string lengths**: Need both values to compare them
2. **Aggregating multiple hashes**: Computing hashes of different inputs
3. **Case transformations**: Upper and lowercase versions of the same string
4. **Validation results**: Multiple validation outcomes for different fields

## Design

### Syntax

The result descriptor `<base: specifier>` is reinterpreted:

| Component | Old Meaning | New Meaning |
|-----------|-------------|-------------|
| `base` | Variable name AND operation | Variable name only |
| `specifier` | Type hint (mostly ignored) | Operation selector |

### New Syntax Pattern

```aro
(* New syntax: base = variable name, specifier = operation *)
<Compute> the <first-len: length> from the <first-message>.   (* binds to 'first-len' *)
<Compute> the <second-len: length> from the <second-message>. (* binds to 'second-len' *)

(* Now both values are available *)
<Compare> the <first-len> against the <second-len>.
```

### Backward Compatibility

The legacy syntax continues to work through operation name detection:

```aro
(* Legacy syntax: base is both variable name AND operation *)
<Compute> the <length> from the <message>.  (* binds to 'length', uses 'length' operation *)
<Compute> the <hash> from the <password>.   (* binds to 'hash', uses 'hash' operation *)
```

The implementation checks if the base identifier is a known operation name when no specifier is provided.

### Affected Actions

| Action | Known Operations |
|--------|-----------------|
| Compute | `hash`, `length`, `count`, `uppercase`, `lowercase`, `identity` |
| Validate | `required`, `exists`, `nonempty`, `email`, `numeric` |
| Transform | `string`, `int`, `integer`, `double`, `float`, `bool`, `boolean`, `json`, `identity` |
| Sort | `ascending`, `descending` |

## Implementation

### Resolution Algorithm

```
function resolveOperationName(result, knownOperations, fallback):
    1. If result.specifiers is not empty:
       return result.specifiers.first  (* New syntax *)

    2. If result.base is in knownOperations:
       return result.base              (* Legacy syntax *)

    3. return fallback                 (* Default operation *)
```

### Examples

| Statement | Variable | Operation |
|-----------|----------|-----------|
| `<Compute> the <msg-len: length> from <msg>.` | msg-len | length |
| `<Compute> the <length> from <msg>.` | length | length |
| `<Compute> the <result> from <msg>.` | result | identity |
| `<Validate> the <email-valid: email> for <input>.` | email-valid | email |
| `<Validate> the <email> for <input>.` | email | email |
| `<Transform> the <user-json: json> from <user>.` | user-json | json |
| `<Sort> the <sorted-desc: descending> for <items>.` | sorted-desc | descending |

## Extended Example

```aro
(Message Analysis: String Processing) {
    (* Extract two messages *)
    <Extract> the <greeting> from the <input: greeting> with "Hello, World!".
    <Extract> the <farewell> from the <input: farewell> with "Goodbye!".

    (* Compute lengths with distinct variable names *)
    <Compute> the <greeting-length: length> from the <greeting>.
    <Compute> the <farewell-length: length> from the <farewell>.

    (* Compute case transformations *)
    <Compute> the <greeting-upper: uppercase> from the <greeting>.
    <Compute> the <greeting-lower: lowercase> from the <greeting>.

    (* Compare the lengths *)
    <Compare> the <greeting-length> against the <farewell-length>.

    (* All variables are available *)
    <Log> {
        greeting: <greeting>,
        farewell: <farewell>,
        greetingLength: <greeting-length>,
        farewellLength: <farewell-length>,
        greetingUpper: <greeting-upper>,
        greetingLower: <greeting-lower>
    } to the <console>.

    <Return> an <OK: status> with <greeting-length>.
}
```

## Extending via Plugins

The `ComputationService` protocol allows plugins to add custom computations:

```swift
public protocol ComputationService: Sendable {
    func compute(named: String, input: Any) async throws -> any Sendable
}
```

Custom computations are invoked using the same qualifier-as-name syntax:

```aro
(* Plugin provides 'sha256' computation *)
<Compute> the <password-hash: sha256> from the <password>.
```

See ARO-0025 for the full plugin extension interface.

## Source Compatibility

This change is fully backward compatible. Existing code using `<Compute> the <length> from <x>.` continues to work because `length` is recognized as a known operation name.

## Alternatives Considered

### 1. Explicit `as` Keyword

```aro
<Compute> the <length as greeting-length> from the <greeting>.
```

Rejected: Requires grammar changes and is more verbose.

### 2. Separate Alias Action

```aro
<Compute> the <length> from the <greeting>.
<Alias> the <length> as <greeting-length>.
```

Rejected: Two statements for one logical operation; verbose.

### 3. Publish for Local Aliasing

```aro
<Compute> the <length> from the <greeting>.
<Publish> as <greeting-length> <length>.
```

Rejected: Publish is designed for cross-feature-set export, not local aliasing.

## References

- ARO-0009: Action Implementations
- ARO-0025: Action Extension Interface
- ARO-0003: Variable Scoping
