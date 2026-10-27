# Chapter 41: Type System

ARO has a simple type system: five built-in primitives, two collection types, and complex types defined externally in OpenAPI. This chapter explains how types work in ARO.

## Primitive Types

ARO has five built-in primitive types:

| Type | Description | Literal Examples |
|------|-------------|-----------------|
| `String` | Text | `"hello"` (regular), `'world'` (raw) |
| `Integer` | Whole numbers | `42`, `-17`, `0xFF`, `1_000_000` |
| `Float` | Decimal numbers, binary (IEEE 754) | `3.14`, `2.5e10`, `1_299.99`, `3.141_592` |
| `Currency` | Decimal numbers, exact (base 10) | no literal of its own — see below |
| `Boolean` | True/False | `true`, `false` |

### `Currency`: Exact Decimal Arithmetic

`Float` is binary floating point, and binary floating point cannot represent `2.40`. So three items at that price is not the number anybody would write on an invoice:

```aro
Compute the <float-total> from <qty> * <price>.                (* 7.199999999999999 *)
Compute the <line-total> as Currency from <qty> * <price>.    (* 7.20 *)
```

That second statement is the whole feature. `Currency` is base-10 arithmetic, exact, and it is requested with the `as` clause on the result — which is also why it has no literal form of its own. A bare `19.99` in source is a `Float`, exactly as it has always been; the format is asked for where a value is *computed*, because that is where the arithmetic happens. `as Decimal` is accepted and means the same format (before GitLab #906 it was a silent alias for `Float`, which is the word that promises exactness delivering the opposite). Prefer the spelling `Currency` in new code: it says *why*.

A `Currency` is a **number**, not a rendering. It serialises as a JSON, CSV and YAML number, and in an HTTP response body, at full precision — a gold CSV reads `99.95`, never `99.94999999999999` and never `"99.95"`.

An amount carries a **scale**, which is its number of decimal places, and the scale comes from the operands rather than being invented. This is the rule SQL's `NUMERIC` and Java's `BigDecimal` follow:

| Operation | Result scale | Exact? |
|-----------|--------------|--------|
| `a + b`, `a - b` | the wider of the two | yes |
| `a * b` | the two scales added, trailing zeros dropped to the wider operand's | yes |
| `a / b` | six places, then trailing zeros dropped to the wider operand's | **no** |
| `a % b` | the wider of the two | yes |

Division is the one operation that cannot be exact, so its rule is stated rather than left to chance: computed at **six decimal places**, rounded **half-up**, then trailing zeros dropped. Six is four more places than any circulating currency's minor unit, so an intermediate division never decides the cents. `6.00 / 2` is `3.00`; `10.00 / 3` is `3.333333`, visibly not exact, which is the honest report. Rescaling — including the `fixed` qualifier of Chapter 9 — rounds half-up away from zero, so `2.345` at two places is `2.35` and `-2.345` is `-2.35`.

Exactness is **contagious**. A statement that reads an exact amount stays exact without repeating the annotation:

```aro
Compute the <line-total> as Currency from <qty> * <price>.
Compute the <with-fee> from <line-total> + 1.05.              (* still exact *)
```

That is what lets a pipeline compute an amount once and have every aggregate downstream agree about it: `sum` of a column of exact amounts is exact, and so are `min`, `max` and a comparison in a `where` or `when` clause.

The limits are 18 decimal places and a scaled value that fits a 64-bit integer. A result that will not fit is a runtime error naming the operation — never a wrapped number and never a quietly rounded one. Multiplication reaches the scale limit first, because the scales add.

Finally, `Currency` carries **no currency code**. It is a precision format, so `as Currency` will add a USD amount to a EUR one without complaint. The code has a home already: ARO-0014's `Money` schema is an object with `amount` and `currency`, declared in `openapi.yaml`. If the arithmetic has to refuse a mismatch, model the amount as `Money` and compare the `currency` fields. The two compose — hold `Money.amount` as a `Currency` and both the exactness and the label are where they belong.

Holding money as whole minor units in an `Integer` and dividing once at the end remains available, and remains the stricter choice for a ledger: an `Integer` cannot acquire a fractional place at all. `Currency` is for the far more common case where the amounts are written in major units and the arithmetic simply has to be right.

### Numeric Literals

Numeric literals support several bases and an optional underscore separator for readability:

```aro
(* Decimal *)
Compute the <million> from 1_000_000.
Compute the <price>   from 1_299.99.
Compute the <pi>      from 3.141_592_653.
Compute the <sci>     from 6.022_141_5e23.

(* Hexadecimal *)
Compute the <color>   from 0xFF_00_FF.

(* Binary *)
Compute the <flags>   from 0b1111_0000.
```

Rules for underscore separators (ARO-0082):

- Underscores may appear **between digits**.
- Underscores may **not** appear at the start or end of a numeric literal, immediately before or after the decimal point, or adjacent to the exponent marker.
- Underscores are stripped during parsing — they have no runtime effect, they are purely a readability aid.

Valid: `1_000`, `0xFF_FF_FF`, `0b1111_0000`, `3.141_592e10`.

Invalid: `_123`, `123_`, `123_.456`, `1e_10`.

### String Literals

ARO supports two types of string literals:

- **Double quotes** `"..."` create regular strings with full escape processing (`\n`, `\t`, `\\`, `\"`, etc.)
- **Single quotes** `'...'` create raw strings where backslashes are literal (only `\'` needs escaping)

```aro
(* Regular string with escape sequences *)
Log "Hello\nWorld" to the <console>.          (* Prints on two lines *)

(* Raw string - backslashes are literal *)
Create the <version-pattern> with '\d+\.\d+\.\d+'.
Create the <config-path> with 'C:\Users\Admin\config.json'.
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

  <!-- Nested -->
  <rect x="400" y="152" width="80" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="440" y="171" text-anchor="middle" font-size="11" fill="#92400e">nested</text>

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
Retrieve the <user: User> from the <user-repository> where <id> = <userId>.
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

## No Optional Types

There is no optional *type* in ARO — no `T?`, no `Option<T>`, nothing to
unwrap. A binding either exists or the statement that would have read it fails
with a message naming what it could not find.

### What Happens When Data Doesn't Exist?

For a field that isn't there, the runtime raises a descriptive error:

```aro
(Get User: API) {
    Extract the <id> from the <pathParameters: id>.
    Extract the <nickname> from the <user: nickname>.
    (* If the field is absent, the runtime says so:
       "Cannot extract the nickname from the user: nickname" *)

    Return an <OK: status> with <nickname>.
}
```

### A Filtered Retrieve Returns an Empty List

The one case that is *not* an error is a repository query that matches nothing.
It binds `[]`, and an empty list is a perfectly good value:

```aro
Retrieve the <user> from the <user-repository> where id = <id>.
Compute the <n: length> from <user>.
(* n = 0 — no error was raised *)
```

This matters because `when <user> is null` never fires for it: `is null` is a
real guard operator, but `[]` is not null. Test the count, or use the `default`
clause (Chapter 36):

```aro
(* Works *)
Retrieve the <found> from the <user-repository> where id = <id>.
Compute the <count: length> from <found>.
Return a <NotFound: status> for the <missing: user> when <count> == 0.

(* Or supply a fallback and skip the check entirely *)
Retrieve the <user> from the <user-repository> where id = <id>
    default { id: <id>, name: "unknown" }.
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
Retrieve the <user> from the <user-repository> where id = <id>
    default { id: <id>, name: "unknown" }.
Log <user: name> to the <console>.
```

The runtime error message IS the error handling. See the Error Handling chapter for more details.

## OpenAPI Without HTTP

You can use OpenAPI just for type definitions, without any HTTP routes:

```yaml
# openapi.yaml - empty paths, just types
openapi: 3.0.3
info:
  title: My Application Types
  version: 1.0.0

# `paths` is required by the loader, but an empty map starts no server.
# Omitting the key entirely fails with "Missing key 'paths'".
paths: {}

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
| Present | Absent | Has schemas | — | Fails to load: `Missing key 'paths'` |
| Present | `{}` | Has schemas | No | Primitives + Schemas |
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
| Primitives | `String`, `Integer`, `Float`, `Currency`, `Boolean` |
| Collections | `List<T>`, `Map<K, V>` |
| Complex types | Defined in `openapi.yaml` components/schemas |
| Optionals | No optional type; a missing field fails, an unmatched query binds `[]` |
| Type annotations | `<name: Type>` |
| Type inference | From literals and expressions |

---

*Next: Chapter 42 — Date and Time and Intervals*
