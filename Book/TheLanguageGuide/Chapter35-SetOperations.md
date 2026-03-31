# Chapter 35: Set Operations

*"Which elements do we share? Which do we keep? Which do we combine?"*

---

## 35.1 Beyond Filtering

The Filter action finds elements in a collection that meet a condition. But many real problems are not about filtering *one* collection — they are about comparing *two* collections: what do they share, what is unique to the first, or what would you get by combining them?

These are set-theoretic questions. ARO answers them with three operations accessed through the Compute action:

```aro
Compute the <result: intersect> from <a> with <b>.
Compute the <result: difference> from <a> with <b>.
Compute the <result: union> from <a> with <b>.
```

Chapter 9 introduced the syntax and type table. This chapter goes deeper: the exact semantics for each type, the `in`/`not in` membership operators, real-world patterns, and how to choose between set operations and other approaches.

---

## 35.2 The Three Operations

<div style="text-align: center; margin: 2em 0;">
<svg width="480" height="110" viewBox="0 0 480 110" xmlns="http://www.w3.org/2000/svg">
  <!-- Intersect -->
  <circle cx="55" cy="52" r="32" fill="#dbeafe" fill-opacity="0.8" stroke="#3b82f6" stroke-width="2"/>
  <circle cx="97" cy="52" r="32" fill="#dcfce7" fill-opacity="0.8" stroke="#22c55e" stroke-width="2"/>
  <path d="M 76 22 A 32 32 0 0 1 76 82 A 32 32 0 0 1 76 22" fill="#7c3aed" fill-opacity="0.5"/>
  <text x="76" y="97" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#4c1d95">intersect</text>
  <text x="76" y="108" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">in both</text>
  <!-- Difference -->
  <circle cx="215" cy="52" r="32" fill="#fee2e2" fill-opacity="0.8" stroke="#ef4444" stroke-width="2"/>
  <circle cx="257" cy="52" r="32" fill="#f3f4f6" fill-opacity="0.8" stroke="#9ca3af" stroke-width="2"/>
  <path d="M 236 22 A 32 32 0 0 1 236 82 A 32 32 0 0 1 236 22" fill="white"/>
  <text x="236" y="97" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#991b1b">difference</text>
  <text x="236" y="108" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">in A, not B</text>
  <!-- Union -->
  <circle cx="375" cy="52" r="32" fill="#fef3c7" fill-opacity="0.8" stroke="#f59e0b" stroke-width="2"/>
  <circle cx="417" cy="52" r="32" fill="#fef3c7" fill-opacity="0.8" stroke="#f59e0b" stroke-width="2"/>
  <text x="396" y="97" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#92400e">union</text>
  <text x="396" y="108" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#6b7280">in A or B</text>
</svg>
</div>

| Operation | Returns | Key property |
|-----------|---------|--------------|
| `intersect` | Elements present in **both** | The overlap |
| `difference` | Elements in **A** but not in **B** | Asymmetric: order matters |
| `union` | All elements from **A or B** | Deduplication, A wins conflicts |

The most important property to remember: **`difference` is not symmetric**. `difference(A, B)` and `difference(B, A)` produce different results. The other two operations treat A and B symmetrically (with `union` giving A priority on conflicts).

---

## 35.3 List Operations

### Basics

```aro
Create the <list-a> with [2, 3, 5].
Create the <list-b> with [1, 2, 3, 4].

Compute the <common: intersect> from <list-a> with <list-b>.
(* [2, 3]      — elements in both    *)

Compute the <only-a: difference> from <list-a> with <list-b>.
(* [5]         — in list-a, not list-b *)

Compute the <only-b: difference> from <list-b> with <list-a>.
(* [1, 4]      — in list-b, not list-a *)

Compute the <all: union> from <list-a> with <list-b>.
(* [2, 3, 5, 1, 4] — all unique elements, A's order first *)
```

### Multiset Semantics

List operations preserve duplicates, counting each element's appearances independently in each list. This is **multiset** (bag) semantics, not set semantics.

**Intersection** preserves up to the *minimum* count in either list:

```aro
Create the <a> with [1, 2, 2, 3, 3, 3].
Create the <b> with [2, 2, 2, 3, 4].

Compute the <common: intersect> from <a> with <b>.
(* [2, 2, 3]
   — 2 appears min(2, 3) = 2 times
   — 3 appears min(3, 1) = 1 time  *)
```

**Difference** removes one occurrence from A for each occurrence in B:

```aro
Create the <a> with [1, 2, 2, 3, 3, 3].
Create the <b> with [2, 3].

Compute the <remaining: difference> from <a> with <b>.
(* [1, 2, 3, 3]
   — one '2' removed (B has one), one '3' removed (B has one) *)
```

**Union** produces all unique elements — each element appears once regardless of how many times it appeared in the inputs:

```aro
Create the <a> with [1, 2, 2, 3].
Create the <b> with [2, 3, 3, 4].

Compute the <all: union> from <a> with <b>.
(* [1, 2, 3, 4] — no duplicates in the result *)
```

### Order Preservation

Results preserve the order elements appear in the inputs. For intersection and difference, the order of A is used. For union, A's elements come first, then unique elements from B in their original order.

---

## 35.4 String Operations

String set operations work on individual characters, treating the string as a sequence of characters:

```aro
Create the <str-a> with "hello".
Create the <str-b> with "bello".

Compute the <shared: intersect> from <str-a> with <str-b>.
(* "ello" — 'l' appears twice in both, 'o' once in both *)

Compute the <unique-to-a: difference> from <str-a> with <str-b>.
(* "h" — 'h' is in "hello" but not in "bello" *)

Compute the <combined: union> from <str-a> with <str-b>.
(* "hellob" — all unique characters, "hello" first, then 'b' from "bello" *)
```

Character operations follow the same multiset semantics as list operations. The string `"aab"` contains two `'a'` characters; the intersection with `"ac"` (which has one `'a'`) yields `"a"` — one `'a'`, the minimum count.

String operations are useful for character-level text analysis:

```aro
(* Find characters common to two words — useful for anagram detection *)
Compute the <shared-letters: intersect> from <word-a> with <word-b>.

(* Find characters that appear in 'a' but not in 'b' *)
Compute the <exclusive: difference> from <word-a> with <word-b>.

(* Build a deduplicated character vocabulary *)
Compute the <vocab: union> from <part-one> with <part-two>.
```

---

## 35.5 Object Operations

Object set operations perform **deep recursive comparison** — nested objects and arrays are processed recursively rather than treated as opaque values.

### Intersection: Keys with Matching Values

The intersection of two objects returns the keys that both objects share **and** whose values are equal. Differing values are excluded:

```aro
Create the <obj-a> with {
    name: "Alice",
    age: 30,
    address: { city: "NYC", zip: "10001" }
}.

Create the <obj-b> with {
    name: "Alice",
    age: 31,
    address: { city: "NYC", state: "NY" }
}.

Compute the <common: intersect> from <obj-a> with <obj-b>.
(* {
     name: "Alice",          -- same in both
     address: { city: "NYC" } -- nested key matching
   }
   age excluded: 30 ≠ 31
   address.zip excluded: only in obj-a
   address.state excluded: only in obj-b *)
```

### Difference: Keys in A That Don't Match B

The difference returns keys that exist in A but whose values differ from B, plus keys present only in A:

```aro
Compute the <changed: difference> from <obj-a> with <obj-b>.
(* {
     age: 30,                  -- value differs (30 vs 31)
     address: { zip: "10001" } -- key not in obj-b
   } *)
```

This makes object difference a **change detection** tool: it answers "what in A is different from B?"

### Union: Merge with A Winning Conflicts

The union merges both objects. When both have the same key, A's value takes precedence:

```aro
Create the <defaults> with { port: 8080, host: "0.0.0.0", timeout: 30 }.
Create the <overrides> with { port: 3000, debug: true }.

Compute the <config: union> from <overrides> with <defaults>.
(* {
     port: 3000,        -- from overrides (A wins)
     host: "0.0.0.0",   -- from defaults (only in B)
     timeout: 30,        -- from defaults (only in B)
     debug: true         -- from overrides (only in A)
   } *)
```

The pattern `union from <overrides> with <defaults>` produces a merged configuration where explicit overrides win and missing keys fall back to defaults.

---

## 35.6 Set Membership in Filter Clauses

Alongside the Compute-based operations, ARO provides `in` and `not in` operators for use in `Filter` and `Retrieve` where clauses. These test whether a field's value is a member of a given set:

```aro
Create the <allowed-statuses> with ["active", "pending"].
Filter the <eligible> from <users> where <status> in <allowed-statuses>.

Create the <blocked-ids> with [42, 99, 150].
Filter the <safe-orders> from <orders> where <id> not in <blocked-ids>.
```

The right-hand side can be a list variable or a literal list. This is often more readable than a long chain of `or` conditions:

```aro
(* Without in: verbose *)
Filter the <terminal> from <orders>
    where <status> = "delivered"
       or <status> = "cancelled"
       or <status> = "refunded".

(* With in: concise *)
Create the <terminal-statuses> with ["delivered", "cancelled", "refunded"].
Filter the <terminal> from <orders> where <status> in <terminal-statuses>.
```

### `in` vs `intersect`

| Tool | When to use |
|------|-------------|
| `Filter ... where <field> in <list>` | Test one field of each item against a set |
| `Compute ... intersect` | Compare two full collections element by element |

`in` operates on a field within each item; `intersect` compares the items themselves. Use `in` when you have a list of objects and want to keep those whose field value appears in a reference set. Use `intersect` when you have two lists of values and want the elements they share.

---

## 35.7 Real-World Patterns

### Permission Management

```aro
(Check Permissions: Permission Check Handler) {
    Extract the <user> from the <event: user>.
    Extract the <user-perms> from the <user: permissions>.
    Extract the <required-perms> from the <event: required>.

    (* What the user has that's needed *)
    Compute the <granted: intersect> from <user-perms> with <required-perms>.

    (* What's still missing *)
    Compute the <missing: difference> from <required-perms> with <user-perms>.

    (* What the user has that wasn't asked for *)
    Compute the <extra: difference> from <user-perms> with <required-perms>.

    Return an <OK: status> with {
        granted: <granted>,
        missing: <missing>,
        hasAll: <missing>
    }.
}
```

### Configuration Merging

A common pattern when building services: apply user-provided settings on top of hardcoded defaults, without requiring the user to specify every field:

```aro
(Apply Config: ConfigReceived Handler) {
    Extract the <user-config> from the <event: config>.

    Create the <defaults> with {
        port: 8080,
        host: "0.0.0.0",
        timeout: 30,
        maxConnections: 100,
        logLevel: "info"
    }.

    (* user-config wins for any shared keys; defaults fill in the rest *)
    Compute the <final-config: union> from <user-config> with <defaults>.

    (* Log only what the user actually customized *)
    Compute the <customized: intersect> from <user-config> with <final-config>.

    Store the <final-config> into the <config-repository>.
    Return an <OK: status> for the <configuration>.
}
```

### Change Detection

Object difference is a natural fit for audit logging and change tracking — it shows exactly what changed between two versions of the same record:

```aro
(Audit Changes: UserUpdated Handler) {
    Extract the <new-user> from the <event: newValue>.
    Extract the <old-user> from the <event: oldValue>.

    (* Fields that changed — their new values *)
    Compute the <changes: difference> from <new-user> with <old-user>.

    (* Fields that stayed the same *)
    Compute the <unchanged: intersect> from <new-user> with <old-user>.

    Create the <audit-record> with {
        userId: <new-user: id>,
        changes: <changes>,
        unchanged: <unchanged>
    }.
    Store the <audit-record> into the <audit-repository>.
    Return an <OK: status> for the <audit>.
}
```

### Data Synchronization

Finding what to add, remove, and keep when syncing two collections:

```aro
(Sync Tags: TagSyncRequested Handler) {
    Extract the <current-tags> from the <event: current>.
    Extract the <desired-tags> from the <event: desired>.

    (* Tags to add: in desired but not yet in current *)
    Compute the <to-add: difference> from <desired-tags> with <current-tags>.

    (* Tags to remove: in current but not in desired *)
    Compute the <to-remove: difference> from <current-tags> with <desired-tags>.

    (* Tags to keep: already correct *)
    Compute the <to-keep: intersect> from <current-tags> with <desired-tags>.

    Emit a <TagsToAdd: event> with <to-add>.
    Emit a <TagsToRemove: event> with <to-remove>.
    Return an <OK: status> for the <sync>.
}
```

This pattern — `difference(desired, current)` gives additions, `difference(current, desired)` gives removals, `intersect(current, desired)` gives what stays — generalises to any synchronisation problem.

---

## 35.8 Chaining Operations

Set operations produce collections, so their results can be used as inputs to further operations:

```aro
Create the <team-a> with ["alice", "bob", "carol"].
Create the <team-b> with ["bob", "dave", "eve"].
Create the <team-c> with ["carol", "dave", "frank"].

(* People on team-a or team-b *)
Compute the <ab: union> from <team-a> with <team-b>.

(* Of those, who is also on team-c? *)
Compute the <on-all-teams: intersect> from <ab> with <team-c>.
(* ["carol", "dave"] *)

(* People on team-a but on neither team-b nor team-c *)
Compute the <ab-union: union> from <team-b> with <team-c>.
Compute the <only-a: difference> from <team-a> with <ab-union>.
(* ["alice"] *)
```

Each step produces an immutable binding that feeds the next. The transformation history is visible at every stage.

---

## 35.9 Set Operations vs Filter

Set operations and the Filter action both work with collections but serve different purposes:

| Use `Filter` when | Use set operations when |
|-------------------|------------------------|
| Applying a condition to each element independently | Comparing two collections against each other |
| Testing field values with complex expressions | Finding overlap or divergence between datasets |
| Transforming individual element fields | Deduplicating or merging collections |
| Working with a single source collection | Working with two collections as inputs |

A Filter runs a predicate on each element. A set operation compares two collections element-by-element. When your problem is "keep only items from A that appear in B," both approaches work, but the intent is different:

```aro
(* Filter approach: for each item in orders, check if its status is in terminal-statuses *)
Create the <terminal-statuses> with ["delivered", "cancelled"].
Filter the <closed> from <orders> where <status> in <terminal-statuses>.

(* Set approach: find the overlap between order status values and terminal-statuses *)
Compute the <order-statuses> from <orders>.   (* not applicable directly *)
```

For field-based membership tests on objects, `Filter ... where <field> in <list>` is usually the right tool. For direct comparison of two collections of values, `intersect` and `difference` are more expressive.

---

## 35.10 Summary

Set operations express collection comparisons as first-class computations:

1. **`intersect`** — elements in both A and B. For objects: keys with matching values. Uses multiset semantics for lists (preserves duplicates up to minimum count).

2. **`difference`** — elements in A not in B. **Asymmetric**: `difference(A, B) ≠ difference(B, A)`. Use it for "what's unique to A" or "what changed in A compared to B."

3. **`union`** — all unique elements from either. For objects: merged result with A winning conflicts. The standard pattern for applying overrides over defaults.

4. **`in` / `not in`** — membership operators for `Filter` and `Retrieve` where clauses, testing a field value against a set without a full `intersect`.

The natural use cases cluster around three themes: **permission checking** (intersect for granted, difference for missing), **configuration** (union with A-wins for overrides over defaults), and **change detection** (difference for what changed between two snapshots).

---

*Next: Chapter 36 — Repositories*
