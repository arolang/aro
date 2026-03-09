# Chapter 41: Type System

ARO has a simple type system: four built-in primitives, two collection types, and complex types defined externally in OpenAPI. This chapter explains how types work in ARO.

## Primitive Types

ARO has four built-in primitive types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text | `"hello"` (regular), `'world'` (raw) |
| `Integer` | Whole numbers | `42`, `-17`, `0xFF` |
| `Float` | Decimal numbers | `3.14`, `2.5e10` |
| `Boolean` | True/False | `true`, `false` |

### String Literals

ARO supports two types of string literals:

- **Double quotes** `"..."` create regular strings with full escape processing (`\n`, `\t`, `\\`, `\"`, etc.)
- **Single quotes** `'...'` create raw strings where backslashes are literal (only `\'` needs escaping)

```aro
(* Regular string with escape sequences *)
Log "Hello\nWorld" to the <console>.          (* Prints on two lines *)

(* Raw string - backslashes are literal *)
Transform <versions> from <text> with regex '\d+\.\d+\.\d+'.
Read <config> from 'C:\Users\Admin\config.json'.
```

Use single quotes when working with regex patterns, file paths, LaTeX commands, or any content with many backslashes. Use double quotes for normal text with escape sequences.

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="220" viewBox="0 0 500 220" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- any Sendable (root) -->
  <rect x="150" y="10" width="200" height="36" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="250" y="33" text-anchor="middle" font-size="12" font-weight="bold" fill="#4338ca">any Sendable</text>

  <!-- Connector lines from root to level 2 -->
  <line x1="200" y1="46" x2="120" y2="84" stroke="#6366f1" stroke-width="1.5"/>
  <line x1="300" y1="46" x2="380" y2="84" stroke="#f59e0b" stroke-width="1.5"/>

  <!-- Scalar -->
  <rect x="50" y="84" width="140" height="36" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="120" y="107" text-anchor="middle" font-size="12" font-weight="bold" fill="#166534">Scalar</text>

  <!-- Collection -->
  <rect x="310" y="84" width="140" height="36" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="380" y="107" text-anchor="middle" font-size="12" font-weight="bold" fill="#92400e">Collection</text>

  <!-- Connector lines from Scalar to level 3 -->
  <line x1="80" y1="120" x2="60" y2="152" stroke="#22c55e" stroke-width="1.5"/>
  <line x1="120" y1="120" x2="120" y2="152" stroke="#22c55e" stroke-width="1.5"/>
  <line x1="160" y1="120" x2="180" y2="152" stroke="#22c55e" stroke-width="1.5"/>

  <!-- Connector lines from Collection to level 3 -->
  <line x1="340" y1="120" x2="320" y2="152" stroke="#f59e0b" stroke-width="1.5"/>
  <line x1="380" y1="120" x2="380" y2="152" stroke="#f59e0b" stroke-width="1.5"/>
  <line x1="420" y1="120" x2="440" y2="152" stroke="#f59e0b" stroke-width="1.5"/>

  <!-- String -->
  <rect x="20" y="152" width="80" height="30" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="60" y="171" text-anchor="middle" font-size="11" fill="#4338ca">String</text>

  <!-- Int/Float -->
  <rect x="80" y="152" width="80" height="30" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="120" y="171" text-anchor="middle" font-size="10" fill="#4338ca">Int/Float</text>

  <!-- Bool -->
  <rect x="140" y="152" width="80" height="30" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="180" y="171" text-anchor="middle" font-size="11" fill="#4338ca">Bool</text>

  <!-- [T] List -->
  <rect x="280" y="152" width="80" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="320" y="171" text-anchor="middle" font-size="11" fill="#92400e">[T] List</text>

  <!-- [K:V] Object -->
  <rect x="340" y="152" width="80" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="380" y="171" text-anchor="middle" font-size="10" fill="#92400e">[K:V] Object</text>

  <!-- T? Optional -->
  <rect x="400" y="152" width="80" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="440" y="171" text-anchor="middle" font-size="11" fill="#92400e">T? Optional</text>

  <!-- OpenAPI bar -->
  <rect x="10" y="196" width="480" height="18" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="250" y="209" text-anchor="middle" font-size="10" fill="#ffffff">OpenAPI schemas — typed against these primitives and collections</text>
</svg>
</div>

## Collection Types

ARO has two built-in collection types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `List<T>` | Ordered collection | `[1, 2, 3]` |
| `Map<K, V>` | Key-value pairs | `{ name: "Alice", age: 30 }` |

### List Examples

```aro
Create the <numbers: List<Integer>> with [1, 2, 3].
Create the <names: List<String>> with ["Alice", "Bob", "Charlie"].

for each <number> in <numbers> {
    Log <number> to the <console>.
}
```

### Map Examples

```aro
Create the <config: Map<String, Integer>> with {
    port: 8080,
    timeout: 30
}.

Extract the <port> from the <config: port>.
```

## Complex Types from OpenAPI

All complex types (records, enums) are defined in `openapi.yaml`. There are no `type` or `enum` keywords in ARO.

### Why OpenAPI?

1. **Single Source of Truth**: Types are defined once, used everywhere
2. **Contract-First**: Design your data before implementing
3. **Documentation**: OpenAPI schemas are self-documenting
4. **Validation**: Runtime can validate against schemas

### Defining Types in OpenAPI

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: My Application
  version: 1.0.0

components:
  schemas:
    User:
      type: object
      properties:
        id:
          type: string
        name:
          type: string
        email:
          type: string
        status:
          $ref: '#/components/schemas/UserStatus'
      required:
        - id
        - name
        - email

    UserStatus:
      type: string
      enum:
        - active
        - inactive
        - suspended
```

### Using OpenAPI Types in ARO

```aro
(Create User: User Management) {
    Extract the <data> from the <request: body>.

    (* User type comes from openapi.yaml *)
    Create the <user: User> with <data>.

    (* Access fields defined in the schema *)
    Log <user: name> to the <console>.

    Return a <Created: status> with <user>.
}
```

## Type Annotations

Type annotations specify the type of a variable.

### Syntax

```aro
<name: Type>
```

### Examples

```aro
<name: String>                    (* Primitive *)
<count: Integer>                  (* Primitive *)
<items: List<String>>             (* Collection of primitives *)
<user: User>                      (* OpenAPI schema reference *)
<users: List<User>>               (* Collection of OpenAPI types *)
<config: Map<String, Integer>>    (* Map with primitives *)
```

### When to Use Type Annotations

Type annotations are optional but recommended when:

- Extracting data from external sources
- Working with OpenAPI schema types
- Clarifying intent in complex operations

```aro
(* Recommended: explicit types for external data *)
Extract the <userId: String> from the <request: body>.
Extract the <items: List<OrderItem>> from the <request: body>.
Retrieve the <user: User> from the <user-repository> where id = <userId>.
```

## Type Inference

Types are inferred from literals and expressions:

```aro
Create the <count> with 42.              (* count: Integer *)
Create the <name> with "John".           (* name: String *)
Create the <active> with true.           (* active: Boolean *)
Create the <price> with 19.99.           (* price: Float *)
Create the <items> with [1, 2, 3].       (* items: List<Integer> *)
```

## No Optionals

ARO has no optional types (`?`, `null`, `undefined`, `Option<T>`). Every variable has a value.

### What Happens When Data Doesn't Exist?

The runtime throws a descriptive error:

```aro
(Get User: API) {
    Extract the <id> from the <pathParameters: id>.
    Retrieve the <user: User> from the <user-repository> where id = <id>.
    (* If user doesn't exist, runtime throws: *)
    (* "Cannot retrieve the user from the user-repository where id = 123" *)

    Return an <OK: status> with <user>.
}
```

### No Null Checks Needed

Traditional code:

```typescript
const user = await repository.find(id);
if (user === null) {
    throw new Error("User not found");
}
console.log(user.name);
```

ARO code:

```aro
Retrieve the <user> from the <user-repository> where id = <id>.
Log <user: name> to the <console>.
```

The runtime error message IS the error handling. See the Error Handling chapter for more details.

## OpenAPI Without HTTP

You can use OpenAPI just for type definitions, without any HTTP routes:

```yaml
# openapi.yaml - No paths, just types
openapi: 3.0.3
info:
  title: My Application Types
  version: 1.0.0

# No paths section = No HTTP server
# But types are still available!

components:
  schemas:
    Config:
      type: object
      properties:
        port:
          type: integer
        host:
          type: string
```

| openapi.yaml | paths | components | HTTP Server | Types Available |
|--------------|-------|------------|-------------|-----------------|
| Missing | - | - | No | Primitives only |
| Present | Empty | Has schemas | No | Primitives + Schemas |
| Present | Has routes | Has schemas | Yes | Primitives + Schemas |

## Type Checking

### Assignment Compatibility

| From | To | Allowed |
|------|-----|---------|
| `T` | `T` | Yes |
| `Integer` | `Float` | Yes (widening) |
| `Float` | `Integer` | Warning (narrowing) |
| `List<T>` | `List<T>` | Yes |
| Schema | Same Schema | Yes |

### Type Errors

| Error | Message |
|-------|---------|
| Type mismatch | `Expected 'String', got 'Integer'` |
| Unknown schema | `Schema 'Foo' not found in openapi.yaml` |
| Missing field | `Schema 'User' has no field 'age'` |

## Summary

| Concept | Details |
|---------|---------|
| Primitives | `String`, `Integer`, `Float`, `Boolean` |
| Collections | `List<T>`, `Map<K, V>` |
| Complex types | Defined in `openapi.yaml` components/schemas |
| Optionals | None - values exist or operations fail |
| Type annotations | `<name: Type>` |
| Type inference | From literals and expressions |

---

*Next: Chapter 42 — Date and Time*
