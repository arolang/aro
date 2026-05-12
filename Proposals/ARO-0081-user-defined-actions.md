# ARO-0081: User-Defined Actions

- **Status:** Accepted (implemented in [Issue #224](https://git.ausdertechnik.de/arolang/aro/-/issues/224))
- **Author:** ARO Language Team
- **Created:** 2026-05-03
- **Related:** ARO-0001 (Language Fundamentals), ARO-0004 (Actions), ARO-0005 (Application Architecture), ARO-0045 (Package Manager — plugin handles)

## Abstract

This proposal introduces **user-defined actions**: feature sets that can be invoked from other feature sets as if they were built-in or plugin actions. A feature set marked with the `Action` business activity becomes callable application-wide as `Application.<Name>`, with a call-site syntax and input/output contract identical to plugin actions (ARO-0045).

## Motivation

Today, the only way to factor reusable logic in ARO is to:

1. Emit an event and write a handler — works, but couples logic to the event bus and requires an asynchronous detour for what is conceptually a synchronous transformation.
2. Wait for a plugin — forces the developer out of ARO into Swift, Rust, C, or Python for what may be a three-line transformation.
3. Inline the logic — copy-paste, no reuse.

ARO already has two callable surfaces:

| Surface | Declared by | Invoked as |
|---------|------------|------------|
| Built-in action | Swift `ActionImplementation` | `Verb the <result> from the <input>.` |
| Plugin action | `plugin.yaml` + handler code | `Handle.Verb the <result> with { ... }.` |

User-defined actions add a third surface that lives entirely in `.aro` source, with the **same call-site shape as plugin actions** so the mental model is uniform.

## Proposed Design

### 1. Declaring an action

A feature set whose business activity is exactly `Action` becomes a callable user-defined action:

```aro
(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    Compute the <result> from <n> * 2.
    Return an <OK: status> with <result>.
}
```

- The activity slot uses the literal keyword `Action`.
- The optional `takes <field>` clause declares the **sugar slot** — the field name a single positional argument binds to (see §4.2).
- The feature set name (`DoubleValue`) becomes the action verb under the `Application` handle.

### 2. Namespace: `Application.`

All user-defined actions live in a single, flat, application-wide namespace prefixed `Application.`:

```aro
Application.DoubleValue the <d> with { number: 5 }.
```

**Rules:**

- Action names are unique application-wide. Defining two `(DoubleValue: Action)` feature sets is a compile error, regardless of file.
- The `Application` handle is reserved exclusively for user-defined actions. Plugin handles (`Greeting`, `Markdown`) and built-in verbs (`Compute`, `Extract`) cannot use it.
- Built-in verbs remain unprefixed and never collide with `Application.<Name>`.

### 3. Calling an action

Call syntax mirrors plugin actions exactly:

```aro
(* Object input — always works *)
Application.DoubleValue the <d> with { number: 5 }.

(* Single-value sugar — works only when the callee declares `takes <field>` *)
Application.DoubleValue the <d> from 5.

(* Variable as object — works when the variable is an object *)
Application.DoubleValue the <d> with <args>.
```

The `with` and `from` prepositions are the only valid forms.

### 4. Input contract

#### 4.1 Object form

The caller passes an object literal or variable. Inside the action body, fields are accessed via the synthetic `<input>` conduit, in the same shape used for `<event: x>`, `<request: body>`, and `<pathParameters: id>`:

```aro
(CreateUser: Action) {
    Extract the <name> from the <input: name>.
    Extract the <email> from the <input: email>.
    (* ... *)
}

(* caller *)
Application.CreateUser the <user> with { name: "Alice", email: "alice@example.com" }.
```

#### 4.2 Single-value sugar

When the action header declares `takes <field>`, callers may pass a single positional value with `from`. The runtime synthesizes an input object with that one field set:

```aro
(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    (* ... *)
}

(* These two calls are equivalent: *)
Application.DoubleValue the <d> from 5.
Application.DoubleValue the <d> with { number: 5 }.
```

The `takes` clause may include a type qualifier, matching ARO's existing typed-result syntax:

```aro
(DoubleValue: Action takes <number: Integer>) { ... }
```

If an action does not declare `takes`, callers must use `with { ... }`. Calling with `from <value>` is a compile error.

### 5. Output contract

The action returns its result via the standard `Return ... with ...` form. The result variable bound at the call site holds the **entire returned object** — `status`, optional `reason`, and every field of the `with` payload, all flattened into one dict:

```aro
(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    Compute the <doubled> from <n> * 2.
    (* Use the object-literal form so the caller can pull a named field *)
    Return an <OK: status> with { doubled: <doubled> }.
}

(* caller *)
Application.DoubleValue the <d> from 5.
(* <d> is now { status: "OK", doubled: 10 } *)
Extract the <result> from the <d: doubled>.
```

The caller always uses `Extract` to pull individual fields. This matches the plugin-action shape (see `Examples/GreetingPlugin/main.aro`) and keeps one mental model for all callable surfaces.

> **Note:** when the body uses `Return an <OK: status> with <variable>` and `<variable>` resolves to a primitive (Int/Double/Bool/String), Return places the value under the `value` key — i.e. callers extract via `<d: value>`. Use the object-literal form `with { name: <variable> }` when you want a specific field name.

### 6. Body restrictions

Inside an `Action` feature set:

| Capability | Allowed? | Notes |
|-----------|----------|-------|
| Emit events | Yes | `Emit a <X: event> with <data>.` works as in any feature set. |
| Call other actions (built-in, plugin, user-defined) | Yes | Including recursion. No tail-call optimization is promised. |
| Read repositories, call HTTP, do file I/O | Yes | All non-framework actions are available. |
| Access framework variables (`request`, `response`, `event`, `pathParameters`, `queryParameters`) | **No** | Compile error. Actions are not event handlers; they have no event/request context. |
| Use `Publish as` to expose globals | Yes | Same scoping rules as any feature set. |

### 7. Compile-time validation

Because all `.aro` files are discovered and parsed before execution (see `ApplicationLoader`), the compiler can fully validate user-defined actions:

- `Application.<Name>` calls referencing a non-existent action → compile error with the list of known actions.
- Duplicate action names → compile error citing both definitions.
- Use of `from <value>` against an action without a `takes` clause → compile error suggesting `with { ... }`.
- Reference to a framework variable inside an `Action` body → compile error.

### 8. Discovery and registration

User-defined actions are discovered by the same mechanism that discovers feature sets today — every `.aro` file in the application directory and its subdirectories is scanned. Any feature set whose activity is `Action` is registered with the `ActionRegistry` under the `Application` handle before `Application-Start` executes.

No imports, no manifests, no aro.yaml entries are required. This matches how event handlers and HTTP routes are wired up.

---

## Worked Example

See `Examples/UserDefinedActions/main.aro` for the runnable version.

```aro
(* math.aro *)

(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    Compute the <doubled> from <n> * 2.
    Return an <OK: status> with { doubled: <doubled> }.
}

(SumAndDouble: Action) {
    Extract the <a> from the <input: a>.
    Extract the <b> from the <input: b>.
    Compute the <sum> from <a> + <b>.

    (* Compose with another user-defined action *)
    Application.DoubleValue the <inner> from <sum>.
    Extract the <answer> from the <inner: doubled>.

    Return an <OK: status> with { value: <answer> }.
}

(* main.aro *)

(Application-Start: Math Demo) {
    Application.SumAndDouble the <answer> with { a: 3, b: 4 }.
    Extract the <total> from the <answer: value>.
    Log <total> to the <console>.   (* prints 14 *)
    Return an <OK: status> for the <startup>.
}
```

---

## Implementation Notes (as shipped)

- **Parser** (`Sources/AROParser/Parser.swift`): the feature-set header now recognises `Action takes <ident[: Type]>`. The activity slot is folded by the existing identifier-sequence reader and `Parser.splitUserActionHeader` decomposes it back into `(activity, takes, type)`. The takes field is stored as `userActionTakesField` / `userActionTakesType` on `FeatureSet`.
- **Semantic analysis** (`Sources/AROParser/UserActionAnalyzer.swift`, `Sources/AROParser/UserActionRegistry.swift`): a single pass builds a `UserActionRegistry` keyed by name and runs validation:
  - duplicate-name detection,
  - unknown `Application.<Name>` calls,
  - `from <value>` against an action without `takes`,
  - framework-variable access (`<request>`, `<event>`, `<pathParameters>`, `<queryParameters>`, `<response>`) inside an Action body.
- **Runtime** (`Sources/ARORuntime/Actions/UserDefinedActionHost.swift`): a single `UserDefinedActionHost` is constructed by `ExecutionEngine.execute` and registers every action under the verb `Application.<Name>` via `ActionRegistry.registerDynamic`. The handler:
  - reads `_with_` / `_expression_` / `_literal_` **locally** on the caller's context (parent-walk would leak the outer call's input into nested calls),
  - synthesises `<input>` from the sugar field when present,
  - spawns a fresh `RuntimeContext` parented to the caller (services and globals stay accessible; framework variables are not copied),
  - runs the body via the standard `FeatureSetExecutor`,
  - flattens the resulting `Response` into `[String: Sendable]` so callers `Extract` fields exactly like plugin actions.
- **No new ABI work**: user-defined actions are pure ARO; no plugin SDK changes are required.

## Future Extensions (out of scope)

- **Multiple sugar slots**: e.g., `takes <a>, <b>` for two-arg positional calls. Deliberately deferred — the object form covers it.
- **Visibility modifiers**: `private` actions confined to a file. Not needed until applications grow large enough to warrant it.
- **Typed action signatures** beyond the single `takes` slot: full input/output schemas in OpenAPI components. Worth considering once usage patterns settle.
- **Cross-application actions**: shared action libraries via the package manager. Plugins already cover this use case via `Handle.Verb`; revisit only if user-defined actions prove popular enough to warrant a sharing story.

## Open Questions

- Should the result merging rule in §5 collapse the `status` field into the variable, or always nest it under `status`? Current draft says merged at the top level, matching how plugins return flat dicts. Worth confirming once we have several real examples.
- Do we want a `Return an <Error: status> with <details>.` shape for failures, and if so, how does it propagate through chained calls? Likely deserves its own proposal alongside ARO-0006 (Error Philosophy).
