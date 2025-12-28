# Chapter 7: Computations

*"Transform what you have into what you need."*

---

## 7.1 The OWN Role

Among the four semantic roles in ARO—REQUEST, OWN, RESPONSE, and EXPORT—the OWN role occupies a special place. While REQUEST brings data in and RESPONSE sends it out, OWN is where the actual work happens. OWN actions transform data that already exists within the feature set, producing new values without external side effects.

The Compute action is the quintessential OWN action. It takes existing bindings, applies operations to them, and produces new bindings. No network calls, no file access, no external dependencies—just pure transformation of data that is already present. This purity makes OWN actions predictable and easy to reason about.

Consider what happens when you compute a string's length. The input string exists in the symbol table, bound to some variable name. The Compute action reads that value, performs a calculation (counting characters), and binds the result to a new variable name. The original string remains unchanged. The new binding appears in the symbol table. The flow continues.

This pattern—read, transform, bind—is the heartbeat of data processing in ARO.

---

## 7.2 Built-in Computations

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

The **length** operation counts elements—characters in strings, items in arrays, keys in dictionaries. The **uppercase** and **lowercase** operations transform case. The **hash** operation produces an integer hash value useful for comparisons.

The **identity** operation, while seemingly trivial, serves an important purpose: it allows arithmetic expressions to be written naturally:

```aro
<Compute> the <total> from <price> * <quantity>.
```

Here, the expression `<price> * <quantity>` is the actual computation. The result binds to `total`. This is identity in action—the expression's result passes through unchanged.

---

## 7.3 Naming Your Results

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

## 7.4 Extending Computations

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

## 7.5 Computation Patterns

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

*Next: Chapter 8 — Understanding Qualifiers*
