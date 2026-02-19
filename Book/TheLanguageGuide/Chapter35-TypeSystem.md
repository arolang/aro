# Chapter 35: Type System

ARO has a simple type system: four built-in primitives, two collection types, and complex types defined externally in OpenAPI. This chapter explains how types work in ARO.

## Primitive Types

ARO has four built-in primitive types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text | `"hello"`, `'world'` |
| `Integer` | Whole numbers | `42`, `-17`, `0xFF` |
| `Float` | Decimal numbers | `3.14`, `2.5e10` |
| `Boolean` | True/False | `true`, `false` |

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

*Next: Chapter 35 — Date and Time*
