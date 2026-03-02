# Chapter 9B: Immutability

*"A variable is a checkpoint, not a container."*

---

## 9B.1 A Feature, Not a Constraint

Every language that forces immutability on its users must answer the same question: why? The honest answer is that immutability is a trade-off—you give up convenient reassignment, and in return you get something more valuable: the ability to read any line of code and know exactly what every variable holds without tracing backwards through the program.

In ARO, bindings are immutable. Once a statement creates a variable, that variable holds that value for the rest of the feature set. No subsequent statement can change it. The compiler enforces this rule at build time, and the runtime enforces it as a secondary check.

This is not merely a safety feature. It shapes how you write ARO code. Instead of maintaining a mental model of "what is `price` right now?"—which shifts every time you see an assignment—you only need to know "where was `price` created?" The answer is always a single statement, and that statement fully describes the value.

The practical effect is that reading ARO code becomes a matter of following a sequence of facts rather than simulating a stateful machine. Each variable is a checkpoint in the data flow: a named, permanent snapshot of the data at that moment in the transformation.

---

## 9B.2 The Binding Rule

When a statement executes, any result it produces is added to the symbol table under the name you specified. That entry is permanent for the duration of the feature set. Attempting to create a new entry under an already-used name is a compile-time error:

```aro
Create the <price> with 100.
Compute the <price> from <price> * 0.8.  (* ERROR: Cannot rebind 'price' *)
```

```
error: Cannot rebind variable 'price' — variables are immutable
  Hint: Create a new variable with a different name instead
  Example: Compute the <discounted-price> from <price> * 0.8
```

The error message itself shows the solution. The compiler does not just tell you what is wrong—it shows you the idiomatic way to write it correctly.

---

## 9B.3 The New-Name Pattern

The fundamental technique for working with immutable bindings is to give each transformation a new, descriptive name that reflects what the value *is* at that stage of the pipeline.

```aro
Create the <price> with 100.
Compute the <discounted-price> from <price> * 0.8.
Compute the <final-price> from <discounted-price> * 1.1.
```

Each name describes the state of the data at that moment. `price` is the original. `discounted-price` is after the discount. `final-price` is after tax. A reader who has never seen this code before knows exactly what each variable represents without needing to look elsewhere.

Compare this to the mutating style that ARO prevents:

```aro
(* This is not valid ARO, but imagine a language where it were: *)
Create the <price> with 100.
Compute the <price> from <price> * 0.8.   (* Now price is 80 *)
Compute the <price> from <price> * 1.1.   (* Now price is 88 *)
```

In that style, `price` is a container that holds different values at different moments. To know what it holds at any point, you must trace all the prior assignments. The variable name stops describing the value and starts describing an *identity* that changes over time.

ARO's model eliminates this cognitive overhead. Every variable name is a fact about what the data *is*, not a label on a changing container.

---

## 9B.4 Naming Variables for the Pipeline

Because you cannot reuse names, choosing good names becomes important. The goal is for each variable to tell the reader something about the stage the data has reached.

**Stage-based naming** is the most readable approach. Think of your data flowing through stages, and let the variable name reflect that stage:

| Stage | Example | What it means |
|-------|---------|----------------|
| Raw input | `raw-body`, `raw-csv`, `raw-input` | Unprocessed, as-received data |
| Parsed | `parsed-order`, `parsed-fields` | Structured but not yet validated |
| Validated | `validated-user`, `clean-email` | Confirmed to meet requirements |
| Enriched | `enriched-order`, `order-with-total` | Original data plus added information |
| Formatted | `formatted-date`, `display-name` | Ready for output |
| Final | `response`, `result`, `summary` | The output product |

This convention creates a readable narrative. When you scan a feature set that contains `raw-data`, `parsed-records`, `valid-records`, and `response`, you can reconstruct the entire processing story from just the variable names.

**Transformation-describing names** work well for mathematical or text operations:

```aro
Create the <revenue> with 12500.
Compute the <monthly-revenue> from <revenue> / 12.
Compute the <rounded-revenue> from <monthly-revenue>.
Compute the <revenue-display: uppercase> from "monthly: ".
```

**Relationship-describing names** work well when combining data from multiple sources:

```aro
Retrieve the <user> from the <user-repository> where id = <user-id>.
Retrieve the <orders> from the <order-repository> where user-id = <user-id>.
Create the <user-profile> with { user: <user>, orders: <orders> }.
```

The name `user-profile` describes the relationship between `user` and `orders` — it is the combined view.

There is no single correct naming scheme. The principle is consistency and descriptiveness within a given feature set. Names should answer the question: "What *is* this value at this point in the program?"

---

## 9B.5 Multi-Step Pipelines

Immutability makes multi-step transformations particularly clear because every intermediate value is permanently named and accessible. You are not discarding intermediate results — you are preserving them.

```aro
(Application-Start: Immutability Demo) {
    Create the <raw-message> with "hello, aro!".
    Compute the <upper-message: uppercase> from <raw-message>.
    Compute the <message-length: length> from <upper-message>.
    Compute the <double-length> from <message-length> * 2.

    Log <raw-message> to the <console>.      (* hello, aro! *)
    Log <upper-message> to the <console>.    (* HELLO, ARO! *)
    Log <message-length> to the <console>.   (* 11           *)
    Log <double-length> to the <console>.    (* 22           *)

    Return an <OK: status> for the <startup>.
}
```

Every stage of the transformation is accessible. You can log any intermediate value, use it in a comparison, include it in a response, or pass it to another action. The pipeline is not a black box — it is a series of named checkpoints.

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="80" viewBox="0 0 520 80" xmlns="http://www.w3.org/2000/svg">
  <rect x="10" y="20" width="100" height="36" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="60" y="35" text-anchor="middle" font-family="monospace" font-size="9" fill="#1e40af">raw-message</text>
  <text x="60" y="48" text-anchor="middle" font-family="monospace" font-size="9" fill="#3b82f6">"hello, aro!"</text>
  <line x1="110" y1="38" x2="135" y2="38" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="135,38 129,34 129,42" fill="#6b7280"/>
  <text x="122" y="32" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">uppercase</text>
  <rect x="135" y="20" width="100" height="36" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="1.5"/>
  <text x="185" y="35" text-anchor="middle" font-family="monospace" font-size="9" fill="#166534">upper-message</text>
  <text x="185" y="48" text-anchor="middle" font-family="monospace" font-size="9" fill="#22c55e">"HELLO, ARO!"</text>
  <line x1="235" y1="38" x2="260" y2="38" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="260,38 254,34 254,42" fill="#6b7280"/>
  <text x="247" y="32" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">length</text>
  <rect x="260" y="20" width="100" height="36" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="310" y="35" text-anchor="middle" font-family="monospace" font-size="9" fill="#92400e">message-length</text>
  <text x="310" y="48" text-anchor="middle" font-family="monospace" font-size="9" fill="#f59e0b">11</text>
  <line x1="360" y1="38" x2="385" y2="38" stroke="#6b7280" stroke-width="1.5"/>
  <polygon points="385,38 379,34 379,42" fill="#6b7280"/>
  <text x="372" y="32" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">* 2</text>
  <rect x="385" y="20" width="100" height="36" rx="5" fill="#f3e8ff" stroke="#a855f7" stroke-width="1.5"/>
  <text x="435" y="35" text-anchor="middle" font-family="monospace" font-size="9" fill="#7c3aed">double-length</text>
  <text x="435" y="48" text-anchor="middle" font-family="monospace" font-size="9" fill="#a855f7">22</text>
</svg>
</div>

This visibility has practical value. If the output is wrong, you can log intermediate values to find exactly where the data diverged from expectations. There is no need to add temporary debug variables that you later remove—every stage already has a name.

---

## 9B.6 Qualifier-as-Name for Repeated Operations

When you apply the same operation to different values, using the operation name alone as your variable name creates a collision:

```aro
Compute the <length> from <first-word>.
Compute the <length> from <second-word>.   (* ERROR: Cannot rebind 'length' *)
```

Both statements attempt to bind `length`. The solution is to use the qualifier-as-name syntax (covered in depth in Chapter 9): put the descriptive variable name in the base position and the operation in the qualifier position.

```aro
Compute the <first-len: length> from <first-word>.
Compute the <second-len: length> from <second-word>.
```

Now `first-len` and `second-len` are both available simultaneously. The qualifier (`:length`) selects the operation; the base (`first-len`, `second-len`) names the result.

This pattern comes up most often with `length`, `count`, `hash`, `uppercase`, and `lowercase`:

```aro
Create the <subject> with "Order #1234".
Create the <body> with "Your order has shipped.".

Compute the <subject-len: length> from <subject>.
Compute the <body-len: length> from <body>.

(* Both values are available: *)
Compute the <total-chars> from <subject-len> + <body-len>.
```

The immutability constraint motivates this syntax. The qualifier-as-name pattern is not just a convenience—it is the answer to the question "how do I apply the same operation twice?"

---

## 9B.7 Loop Body Isolation

Variables created inside a loop body are isolated to that iteration. Each iteration executes in a fresh child context. The loop variable itself is rebound for each iteration (by the runtime, not by user code), and any variables created inside the loop body exist only for that iteration's duration.

```aro
Create the <prices> with [10, 25, 50].

for each <item-price> in <prices> {
    Compute the <taxed-price> from <item-price> * 1.2.
    Log "price:" to the <console>.
    Log <item-price> to the <console>.
    Log "after tax:" to the <console>.
    Log <taxed-price> to the <console>.
}
```

In each iteration, `item-price` is bound to the current element and `taxed-price` is computed from it. Neither variable leaks out of the loop. After the loop, neither `item-price` nor `taxed-price` is accessible — they belonged to the iterations that created them.

This isolation is a form of immutability extended to the time dimension. Just as a variable cannot be rebound within a single execution, a variable cannot escape the scope where it was created and be rebound somewhere else.

The practical benefit is that loop iterations cannot interfere with each other. A variable named `temp` in one iteration and `temp` in the next iteration are completely independent — there is no shared mutable state between iterations.

---

## 9B.8 Reading Immutable Code

One of the most underrated benefits of immutability is that it changes how you read code. In a mutable language, reading a variable reference requires asking: "What was this last assigned to?" In ARO, reading a variable reference requires only: "What statement created this?"

This is a single, directed lookup. You scan backwards until you find the statement that begins with the variable name in the result position. That statement fully describes the value. You do not need to continue scanning.

Compare these two mental models:

**Mutable model**: "Where is `price` now? It was 100, then discounted to 80, then taxed to 88. So it's 88 here."

**Immutable model**: "What is `final-price`? It was computed from `discounted-price * 1.1` on line 12. Done."

This difference is small for short feature sets and large for complex ones. When a feature set has thirty statements, being able to look up any variable's definition in one step — rather than tracing a history of assignments — significantly reduces cognitive load.

---

## 9B.9 Common Anti-Patterns

Understanding what to avoid helps cement the right approach.

**Anti-pattern: Generic stage names**

```aro
Create the <data> with "hello, aro!".
Compute the <data2: uppercase> from <data>.
Compute the <data3: length> from <data2>.
```

Sequential suffixes (`data`, `data2`, `data3`) carry no information about what happened between steps. A reader cannot tell from the names whether `data2` is the uppercase version, the trimmed version, or something else entirely.

**Anti-pattern: Trying to simulate mutation with a long chain of similar names**

```aro
Create the <x1> with <raw-value>.
Compute the <x2> from <x1> * 0.9.
Compute the <x3> from <x2> + 5.
Compute the <x4> from <x3> * 1.1.
```

This is the naming pattern of someone thinking in terms of a mutable variable `x` that they wish they could update. The numbered names reveal that the developer is trying to track one evolving value rather than a series of distinct transformations. Use names that describe what the value *is* at each stage, not where it is in a sequence.

**Anti-pattern: Using qualifiers to "rename" rather than to select operations**

```aro
Compute the <result: identity> from <input>.
```

The `identity` qualifier returns its input unchanged — it is a no-op transformation. Using it solely to move a value from one name to another works, but it reads oddly. If you need to alias a value, consider whether the original name is reusable or whether the downstream code can simply reference the original.

---

## 9B.10 Immutability Across Feature Sets

Immutability applies within a single feature set. Across feature sets, ARO provides scoped mechanisms for sharing state:

- **Published variables** are bound once during Application-Start (or another feature set in the same business activity) and read by other feature sets. They are effectively immutable from the consumer's perspective—you can only read them, not write to them.

- **Repositories** are mutable stores that sit outside any feature set. A `Store` operation appends to a repository; a `Retrieve` operation reads from it. The per-feature-set symbol table is still immutable, but you can express change by storing new entries and retrieving the latest state.

- **Events** carry immutable payloads. When a feature set emits an event, the payload is fixed at the moment of emission. Handlers receive that snapshot—they cannot modify the payload, only extract values from it.

This layered model keeps the reasoning benefits of immutability where they matter most (inside feature sets, where the code is dense) while still allowing application state to evolve over time (through repositories and events, where the mechanisms are explicit).

---

## 9B.11 Summary

ARO's immutability model produces code where every variable name is a permanent fact about the data at that point in the transformation. Key principles:

1. **Variables are bound, not assigned.** Once created, a binding is permanent within its feature set.

2. **Transformations produce new names.** The new-name pattern — giving each stage a descriptive name — is the primary way to express change.

3. **Names should reflect stage.** `validated-email`, `enriched-order`, `formatted-response` — let the name tell the story of what happened to the data.

4. **Qualifier-as-name resolves operation collisions.** When the same operation applies to multiple values, `<greeting-len: length>` and `<farewell-len: length>` keep them distinct.

5. **Loop bodies are isolated.** Each iteration gets fresh bindings that do not outlive the iteration.

6. **Every variable is a checkpoint.** You can inspect, log, or use any intermediate value without adding temporary bindings. The pipeline documents itself.

The immutability rule is not a limitation that forces workarounds. It is a design constraint that steers code toward a form where data flow is visible, every variable's meaning is clear, and the history of any value can be reconstructed by reading from a single point.

---

*Next: Chapter 10 — The Happy Path*
