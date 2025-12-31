# Chapter 8: Computations

*"Transform what you have into what you need."*

---

## 8.1 The OWN Role

Among the four semantic roles in ARO—REQUEST, OWN, RESPONSE, and EXPORT—the OWN role occupies a special place. While REQUEST brings data in and RESPONSE sends it out, OWN is where the actual work happens. OWN actions transform data that already exists within the feature set, producing new values without external side effects.

The Compute action is the quintessential OWN action. It takes existing bindings, applies operations to them, and produces new bindings. No network calls, no file access, no external dependencies—just pure transformation of data that is already present. This purity makes OWN actions predictable and easy to reason about.

Consider what happens when you compute a string's length. The input string exists in the symbol table, bound to some variable name. The Compute action reads that value, performs a calculation (counting characters), and binds the result to a new variable name. The original string remains unchanged. The new binding appears in the symbol table. The flow continues.

This pattern—read, transform, bind—is the heartbeat of data processing in ARO.

---

## 8.2 Built-in Computations

ARO provides several built-in computations that cover common transformation needs:

<div style="display: flex; flex-wrap: wrap; justify-content: center; gap: 1em; margin: 2em 0;">

<div style="text-align: center;">
<svg width="120" height="80" viewBox="0 0 120 80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="20" width="100" height="40" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>
  <text x="60" y="35" text-anchor="middle" font-family="monospace" font-size="10" fill="#1e40af">"Hello"</text>
  <text x="60" y="50" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#3b82f6">→ 5</text>
  <text x="60" y="72" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#1e40af">length</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="120" height="80" viewBox="0 0 120 80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="20" width="100" height="40" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="60" y="35" text-anchor="middle" font-family="monospace" font-size="10" fill="#166534">"hello"</text>
  <text x="60" y="50" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#22c55e">→ "HELLO"</text>
  <text x="60" y="72" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#166534">uppercase</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="120" height="80" viewBox="0 0 120 80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="20" width="100" height="40" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="60" y="35" text-anchor="middle" font-family="monospace" font-size="10" fill="#92400e">"HELLO"</text>
  <text x="60" y="50" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#f59e0b">→ "hello"</text>
  <text x="60" y="72" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#92400e">lowercase</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="120" height="80" viewBox="0 0 120 80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="20" width="100" height="40" rx="5" fill="#f3e8ff" stroke="#a855f7" stroke-width="2"/>
  <text x="60" y="35" text-anchor="middle" font-family="monospace" font-size="10" fill="#7c3aed">"secret"</text>
  <text x="60" y="50" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#a855f7">→ 839201</text>
  <text x="60" y="72" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#7c3aed">hash</text>
</svg>
</div>

</div>

The **length** and **count** operations count elements—characters in strings, items in arrays, keys in dictionaries. While interchangeable for most purposes, `length` is typically used for strings and `count` for collections. The **uppercase** and **lowercase** operations transform case. The **hash** operation produces an integer hash value useful for comparisons.

The **identity** operation, while seemingly trivial, serves an important purpose: it allows arithmetic expressions to be written naturally:

```aro
<Compute> the <total> from <price> * <quantity>.
```

Here, the expression `<price> * <quantity>` is the actual computation. The result binds to `total`. This is identity in action—the expression's result passes through unchanged.

---

## 8.3 Naming Your Results

A subtle problem arises when you need multiple results of the same operation. Consider computing the lengths of two different messages:

```aro
<Compute> the <length> from the <greeting>.
<Compute> the <length> from the <farewell>.  (* Overwrites! *)
```

Since ARO variables are immutable within their scope, the second statement overwrites the first. Both computations produce lengths, but only the last one survives.

The solution is the **qualifier-as-name** syntax. In this pattern, the qualifier specifies the operation while the base becomes the variable name:

```aro
<Compute> the <greeting-length: length> from the <greeting>.
<Compute> the <farewell-length: length> from the <farewell>.
```

Now both lengths exist with distinct names. You can compare them:

```aro
<Compare> the <greeting-length> against the <farewell-length>.
```

This syntax separates two concerns that were previously conflated:
- The **base** (`greeting-length`) is what you want to call the result
- The **qualifier** (`length`) is what operation to perform

The same pattern works with all computed operations:

```aro
<Compute> the <name-upper: uppercase> from the <name>.
<Compute> the <name-lower: lowercase> from the <name>.
<Compute> the <password-hash: hash> from the <password>.
```

For backward compatibility, the original syntax still works. Writing `<Compute> the <length> from <msg>.` recognizes `length` as both the variable name and the operation.

---

## 8.4 Set Operations

When working with collections, you often need to find commonalities or differences between datasets. ARO provides three polymorphic set operations that work across Lists, Strings, and Objects.

<div style="display: flex; flex-wrap: wrap; justify-content: center; gap: 1.5em; margin: 2em 0;">

<div style="text-align: center;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">
  <circle cx="55" cy="50" r="35" fill="#dbeafe" fill-opacity="0.7" stroke="#3b82f6" stroke-width="2"/>
  <circle cx="105" cy="50" r="35" fill="#dcfce7" fill-opacity="0.7" stroke="#22c55e" stroke-width="2"/>
  <path d="M 70 25 A 35 35 0 0 1 70 75 A 35 35 0 0 1 70 25" fill="#7c3aed" fill-opacity="0.4"/>
  <text x="80" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#7c3aed">intersect</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">
  <circle cx="55" cy="50" r="35" fill="#f87171" fill-opacity="0.5" stroke="#ef4444" stroke-width="2"/>
  <circle cx="105" cy="50" r="35" fill="#e5e7eb" fill-opacity="0.5" stroke="#9ca3af" stroke-width="2"/>
  <path d="M 70 25 A 35 35 0 0 1 70 75 A 35 35 0 0 1 70 25" fill="white"/>
  <text x="80" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#ef4444">difference</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="160" height="100" viewBox="0 0 160 100" xmlns="http://www.w3.org/2000/svg">
  <circle cx="55" cy="50" r="35" fill="#fbbf24" fill-opacity="0.5" stroke="#f59e0b" stroke-width="2"/>
  <circle cx="105" cy="50" r="35" fill="#fbbf24" fill-opacity="0.5" stroke="#f59e0b" stroke-width="2"/>
  <text x="80" y="92" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#d97706">union</text>
</svg>
</div>

</div>

### List Operations

The most common use case is comparing two lists:

```aro
<Create> the <list-a> with [2, 3, 5].
<Create> the <list-b> with [1, 2, 3, 4].

<Compute> the <common: intersect> from <list-a> with <list-b>.
(* Result: [2, 3] — elements in both *)

<Compute> the <only-in-a: difference> from <list-a> with <list-b>.
(* Result: [5] — elements in A but not B *)

<Compute> the <all: union> from <list-a> with <list-b>.
(* Result: [2, 3, 5, 1, 4] — all unique elements *)
```

Set operations use **multiset semantics** for duplicates. When lists contain repeated elements, the intersection preserves duplicates up to the minimum count in either list:

```aro
<Create> the <a> with [1, 2, 2, 3].
<Create> the <b> with [2, 2, 2, 4].

<Compute> the <common: intersect> from <a> with <b>.
(* Result: [2, 2] — two 2s appear in both *)

<Compute> the <remaining: difference> from <a> with <b>.
(* Result: [1, 3] — removes two 2s from a *)
```

### String Operations

The same operations work on strings at the character level:

```aro
<Compute> the <shared: intersect> from "hello" with "bello".
(* Result: "ello" — characters in both, preserving order *)

<Compute> the <unique: difference> from "hello" with "bello".
(* Result: "h" — characters in first, not in second *)

<Compute> the <combined: union> from "hello" with "bello".
(* Result: "hellob" — all unique characters *)
```

### Object Operations (Deep Comparison)

For objects, set operations perform **deep recursive comparison**. The intersection finds keys where both objects have matching values:

```aro
<Create> the <obj-a> with {
    name: "Alice",
    age: 30,
    address: { city: "NYC", zip: "10001" }
}.

<Create> the <obj-b> with {
    name: "Alice",
    age: 31,
    address: { city: "NYC", state: "NY" }
}.

<Compute> the <common: intersect> from <obj-a> with <obj-b>.
(* Result: { name: "Alice", address: { city: "NYC" } } *)
(* Only fields with matching values are included *)

<Compute> the <diff: difference> from <obj-a> with <obj-b>.
(* Result: { age: 30, address: { zip: "10001" } } *)
(* Fields in A that differ from or don't exist in B *)

<Compute> the <merged: union> from <obj-a> with <obj-b>.
(* Result: merged object with A winning conflicts *)
```

### Type Behavior Summary

| Operation | Lists | Strings | Objects |
|-----------|-------|---------|---------|
| **intersect** | Elements in both (multiset) | Chars in both (order preserved) | Keys with matching values (recursive) |
| **difference** | In A, not in B | Chars in A, not in B | Keys/values in A, not matching B |
| **union** | All unique elements | All unique chars | Merge keys (A wins conflicts) |

---

## 8.5 Extending Computations

The built-in operations cover common cases, but real applications often need domain-specific computations. ARO's plugin system allows you to add custom operations that integrate seamlessly with the Compute action.

Plugins implement the `ComputationService` protocol:

```swift
public protocol ComputationService: Sendable {
    func compute(named: String, input: Any) async throws -> any Sendable
}
```

When the Compute action executes, it first checks for a registered computation service. If one exists, it delegates to the plugin. This allows plugins to provide operations like cryptographic hashes, custom string transformations, or domain-specific calculations.

A cryptography plugin might provide:

```aro
<Compute> the <password-hash: sha256> from the <password>.
<Compute> the <signature: hmac> from the <message>.
```

A formatting plugin might provide:

```aro
<Compute> the <formatted-date: iso8601> from the <timestamp>.
<Compute> the <money-display: currency> from the <amount>.
```

The syntax remains consistent regardless of whether the operation is built-in or plugin-provided. This uniformity means you can start with built-in operations and add plugins later without changing how your code reads.

See Chapter 17 for the full plugin development guide.

---

## 8.6 Computation Patterns

Several patterns emerge in how computations are used within feature sets.

**Derived values** compute new data from existing bindings:

```aro
<Extract> the <price> from the <product: price>.
<Extract> the <quantity> from the <order: quantity>.
<Compute> the <subtotal> from <price> * <quantity>.
<Compute> the <tax> from <subtotal> * 0.08.
<Compute> the <total> from <subtotal> + <tax>.
```

**Normalization** ensures consistent data formats:

```aro
<Extract> the <email> from the <input: email>.
<Compute> the <normalized-email: lowercase> from the <email>.
```

**Chained transformations** build complex results step by step:

```aro
<Compute> the <base> from <quantity> * <unit-price>.
<Compute> the <discounted> from <base> * (1 - <discount-rate>).
<Compute> the <with-tax> from <discounted> * (1 + <tax-rate>).
```

**Aggregation** combines collection data:

```aro
<Retrieve> the <orders> from the <order-repository>.
<Compute> the <order-count: count> from the <orders>.
```

Each pattern follows the read-transform-bind rhythm. Data flows forward, transformations produce new values, and the symbol table accumulates bindings that subsequent statements can use.

---

*Next: Chapter 9 — Understanding Qualifiers*
