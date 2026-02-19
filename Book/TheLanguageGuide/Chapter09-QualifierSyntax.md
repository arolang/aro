# Chapter 9: Understanding Qualifiers

*"The colon is context-aware: it navigates data or selects operations."*

---

## 9.1 The Two Roles of Qualifiers

Throughout ARO, you encounter the colon syntax `<name: qualifier>`. This compact notation carries significant meaning, but that meaning depends on context. Understanding when the colon navigates data versus when it selects operations is essential for writing clear ARO code.

The qualifier serves two distinct purposes:

| Context | Role | Example |
|---------|------|---------|
| **Operations** (Compute, Transform, Sort) | Selects which operation to perform | `<len: length>` |
| **Data Access** (Extract, Objects) | Navigates to nested properties | `<event: user>` |

This distinction matters because the same syntax produces fundamentally different results depending on the action being performed.

---

## 9.2 Operation Qualifiers

When using actions like Compute, Validate, Transform, or Sort, the qualifier specifies which operation to apply. The base identifier becomes the variable name for the result.

### The Problem: Name Collisions

Consider computing lengths of multiple strings:

```aro
Compute the <length> from the <greeting>.
Compute the <length> from the <farewell>.
```

Both statements attempt to bind to `length`. Since ARO variables are immutable within a scope, the second overwrites the first. You lose the greeting's length.

### The Solution: Qualifier-as-Name

Separate the variable name from the operation:

```aro
Compute the <greeting-length: length> from the <greeting>.
Compute the <farewell-length: length> from the <farewell>.
```

Now `greeting-length` holds 12 and `farewell-length` holds 8. Both values exist simultaneously, ready for comparison:

```aro
Compare the <greeting-length> against the <farewell-length>.
```

### Available Operations by Action

| Action | Operations |
|--------|-----------|
| **Compute** | `length`, `count`, `hash`, `uppercase`, `lowercase`, `identity` |
| **Validate** | `required`, `exists`, `nonempty`, `email`, `numeric` |
| **Transform** | `string`, `int`, `integer`, `double`, `float`, `bool`, `boolean`, `json`, `identity` |
| **Sort** | `ascending`, `descending` |

### Examples

```aro
(* Multiple computations with distinct names *)
Compute the <name-upper: uppercase> from the <name>.
Compute the <name-lower: lowercase> from the <name>.
Compute the <name-len: length> from the <name>.

(* Validation with named results *)
Validate the <email-valid: email> for the <input-email>.
Validate the <age-valid: numeric> for the <input-age>.

(* Transformations *)
Transform the <user-json: json> from the <user>.
Transform the <count-str: string> from the <count>.
```

---

## 9.3 Field Navigation Qualifiers

When accessing data from objects, events, or requests, the qualifier navigates to nested properties. The qualifier acts as a path into the data structure.

### Single-Level Access

```aro
(* Extract user from event payload *)
Extract the <user> from the <event: user>.

(* Extract body from request *)
Extract the <data> from the <request: body>.

(* Extract id from path parameters *)
Extract the <user-id> from the <pathParameters: id>.
```

### Deep Navigation

For nested structures, use dot-separated paths:

```aro
(* Access deeply nested data *)
Extract the <city> from the <user: address.city>.
Extract the <zip> from the <user: address.postal-code>.

(* Navigate through arrays and objects *)
Extract the <first-name> from the <response: data.users.0.name>.
```

### Common Patterns

```aro
(* HTTP request handling *)
Extract the <auth-token> from the <request: headers.Authorization>.
Extract the <content-type> from the <request: headers.Content-Type>.

(* Event handling *)
Extract the <order> from the <event: payload.order>.
Extract the <customer-id> from the <event: payload.order.customer-id>.

(* Configuration access *)
Extract the <timeout> from the <config: server.timeout>.
Extract the <max-retries> from the <config: server.retry.max-attempts>.
```

---

## 9.4 Type Annotations with `as`

For data pipeline operations (Filter, Reduce, Map), you can optionally specify result types using the `as` keyword:

```aro
(* Without type - inferred automatically *)
Filter the <active-users> from the <users> where <active> is true.

(* With explicit type using 'as' *)
Filter the <active-users> as List<User> from the <users> where <active> is true.

(* Reduce with type for precision *)
Reduce the <total> as Float from the <orders> with sum(<amount>).
```

Type annotations are **optional** because ARO infers result types from the operation. Use explicit types when:

1. You need a specific numeric precision (Float vs Integer)
2. You want documentation in the code
3. You're overriding default inference

See ARO-0038 for the full specification.

---

## 9.5 The Ambiguity Case

A natural question arises: what happens when data contains a field named like an operation?

```aro
Create the <data> with { length: 42, items: [1, 2, 3] }.
```

If you write:

```aro
Compute the <len: length> from the <data>.
```

What does ARO compute? The `length` field (42) or the length of `data` (2 keys)?

**The rule**: Operation qualifiers apply to the action's semantic meaning, not field access. The Compute action computes `length` (the operation) on `data`, returning 2 (two keys in the dictionary).

To access the `length` field, use Extract:

```aro
Extract the <len> from the <data: length>.
```

This returns 42—the value of the `length` field.

### Summary of Resolution

| Statement | Interpretation | Result |
|-----------|---------------|--------|
| `Compute the <len: length> from <data>.` | Compute length of data | 2 |
| `Extract the <len> from <data: length>.` | Extract length field | 42 |

---

## 9.6 Best Practices

**Use descriptive base names with operation qualifiers:**

```aro
(* Good: Clear what each variable holds *)
Compute the <greeting-length: length> from the <greeting>.
Compute the <password-hash: hash> from the <password>.

(* Avoid: Unclear what 'len' or 'h' represent *)
Compute the <len: length> from the <greeting>.
Compute the <h: hash> from the <password>.
```

**Keep object structures shallow when possible:**

Deeply nested paths become hard to read and maintain. Consider flattening data structures or extracting intermediate values:

```aro
(* Hard to read *)
Extract the <name> from the <response: data.results.0.user.profile.name>.

(* Clearer with intermediate steps *)
Extract the <user> from the <response: data.results.0.user>.
Extract the <profile> from the <user: profile>.
Extract the <name> from the <profile: name>.
```

**When ambiguity exists, prefer explicit actions:**

If a field name collides with an operation name, use the appropriate action explicitly rather than relying on context resolution:

```aro
(* Explicit about intent *)
Extract the <len-value> from the <obj: length>.     (* Get the field *)
Compute the <obj-size: count> from the <obj>.       (* Count the keys *)
```

In summary, qualifiers serve two purposes: navigating data structures and selecting operations.

```aro
Extract the <city> from the <user: address.city>.
Compute the <name-upper: uppercase> from the <name>.
```

---

*Next: Chapter 10 — The Happy Path*
