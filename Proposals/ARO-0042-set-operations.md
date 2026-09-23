# ARO-0042: Set Operations

* Proposal: ARO-0042
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004

## Abstract

This proposal defines set operations (`intersect`, `difference`, `union`) for collections. These operations work on lists, strings, and objects with consistent semantics, enabling powerful data manipulation through the Compute action.

---

## 1. Syntax

### 1.1 General Form

```aro
Compute the <result: operation> from <a> with <b>.
```

Where `operation` is one of:
- `intersect` - Elements in both A and B
- `difference` - Elements in A but not in B
- `union` - All elements from A and B (deduplicated)
- `symmetric-difference` - Elements in exactly one of A and B (§3.7)

**`subset of` is not in this list, and deliberately.** It is a *predicate*, not
an operation that produces a collection, so it is a condition operator rather
than a Compute qualifier — see §3.6.

### 1.2 Examples

```aro
Create the <list-a> with [1, 2, 3, 4].
Create the <list-b> with [3, 4, 5, 6].

Compute the <common: intersect> from <list-a> with <list-b>.
(* common = [3, 4] *)

Compute the <only-a: difference> from <list-a> with <list-b>.
(* only-a = [1, 2] *)

Compute the <all: union> from <list-a> with <list-b>.
(* all = [1, 2, 3, 4, 5, 6] *)
```

---

## 2. Supported Types

Set operations work on three collection types:

| Type | Description |
|------|-------------|
| **List** | Arrays of any elements |
| **String** | Character sequences |
| **Object** | Dictionaries with string keys |

---

## 3. List Operations

### 3.1 Multiset Semantics

List operations use **multiset semantics**—duplicate elements are tracked by count.

### 3.2 Intersect

Returns elements present in both lists, preserving duplicates up to the minimum count:

```aro
Create the <a> with [1, 2, 2, 3, 3, 3].
Create the <b> with [2, 2, 2, 3, 4].

Compute the <result: intersect> from <a> with <b>.
(* result = [2, 2, 3] *)
(* 2 appears min(2,3)=2 times, 3 appears min(3,1)=1 time *)
```

### 3.3 Difference

Returns elements from A minus occurrences in B (multiset subtraction):

```aro
Create the <a> with [1, 2, 2, 3, 3, 3].
Create the <b> with [2, 3].

Compute the <result: difference> from <a> with <b>.
(* result = [1, 2, 3, 3] *)
(* One '2' removed, one '3' removed *)
```

### 3.4 Union

Returns all unique elements from both lists (A elements first, then unique B elements):

```aro
Create the <a> with [1, 2, 3].
Create the <b> with [3, 4, 5].

Compute the <result: union> from <a> with <b>.
(* result = [1, 2, 3, 4, 5] *)
```

### 3.5 Complex Elements

Operations work with complex elements (objects, arrays):

```aro
Create the <users-a> with [
    { name: "Alice", role: "admin" },
    { name: "Bob", role: "user" }
].
Create the <users-b> with [
    { name: "Bob", role: "user" },
    { name: "Carol", role: "admin" }
].

Compute the <common-users: intersect> from <users-a> with <users-b>.
(* common-users = [{ name: "Bob", role: "user" }] *)
```

### 3.6 Subset — a predicate, not an operation

```aro
when <required-roles> subset of <user-roles> {
    Return an <OK: status> for the <request>.
}
```

Every other operation here takes two collections and produces a third.
`subset of` takes two collections and answers a question, so it belongs with
`in`, `contains` and `matches` in ARO-0002's operator table rather than in the
qualifier table above (GitLab #864). Writing it as a qualifier would mean
`Compute the <ok: subset> from <a> with <b>.` followed by a guard on `<ok>` —
two statements where the language already has a shape for one.

Until it existed this was written as an intersect plus a length comparison:

```aro
(* What this replaces — and it is not quite the same question *)
Compute the <both: intersect> from <required> with <granted>.
Compute the <n: length> from <both>.
Compute the <m: length> from <required>.
Return an <OK: status> for the <request> when <n> is <m>.
```

Not quite the same question, because `intersect` is multiset: if `required`
lists a role twice, the lengths differ even when every required role is
granted.

**Set semantics, not multiset.** `[1, 1] subset of [1]` is true: the question
is about membership, and a duplicate does not make a new member. This is the
one place in ARO-0042 that is not multiset, because "does this list contain
everything that one does" is the question people ask and counting duplicates
answers a different one.

**The empty set is a subset of everything**, including itself — the
mathematical convention, and the useful one: a route that requires no roles
admits every caller.

| Left | Right | True when |
|------|-------|-----------|
| List | List | every element of the left appears in the right |
| List | Object | every element of the left is a key of the right |
| String | String | every character of the left appears in the right |
| Object | Object | every key of the left is in the right, with an equal value |
| Scalar | any of the above | the scalar is a member — a bare value counts as a one-element set |

There is no `superset of`. It is `subset of` with the operands the other way
round, and a second spelling for one relation is a second thing to get wrong.

### 3.7 Symmetric difference

```aro
Create the <before> with ["read", "write", "admin"].
Create the <after> with ["read", "write", "billing"].

Compute the <changed: symmetric-difference> from <before> with <after>.
(* changed = ["admin", "billing"] *)
```

Everything in exactly one of the two — which is to say, what changed. It was
written as two differences and a union: three statements and two intermediate
bindings for one question.

It is *defined* as those three operations, not reimplemented, so it inherits
their per-type behaviour exactly — multiset for lists, character-wise for
strings, deep for objects. Defining it independently would be a second answer
to "what does difference mean for an object", and the two would drift.

The symmetric difference of a collection with itself is empty, which is the
cheapest "did anything change" a program can ask.

---

## 4. String Operations

### 4.1 Character-Based

String operations work on individual characters, preserving order from the first operand.

### 4.2 Intersect

Returns characters present in both strings (preserving order and count from A up to B's count):

```aro
Create the <a> with "hello".
Create the <b> with "world".

Compute the <result: intersect> from <a> with <b>.
(* result = "lo" *)
(* 'l' and 'o' are in both strings *)
```

### 4.3 Difference

Returns characters from A not consumed by B:

```aro
Create the <a> with "hello".
Create the <b> with "help".

Compute the <result: difference> from <a> with <b>.
(* result = "lo" *)
(* 'h', 'e', 'l' consumed by "help", leaving 'l', 'o' *)
```

### 4.4 Union

Returns all characters from A, plus unique characters from B not already in A:

```aro
Create the <a> with "abc".
Create the <b> with "cde".

Compute the <result: union> from <a> with <b>.
(* result = "abcde" *)
```

---

## 5. Object Operations

### 5.1 Deep Recursive

Object operations are **deep recursive**—nested objects and arrays are processed recursively.

### 5.2 Intersect

Returns keys present in both with matching values:

```aro
Create the <a> with {
    name: "Alice",
    settings: { theme: "dark", notifications: true },
    roles: ["admin", "user"]
}.
Create the <b> with {
    name: "Alice",
    settings: { theme: "dark", notifications: false },
    roles: ["user", "guest"]
}.

Compute the <result: intersect> from <a> with <b>.
(* result = {
     name: "Alice",
     settings: { theme: "dark" },
     roles: ["user"]
   }
*)
```

### 5.3 Difference

Returns keys/values in A that are not matching in B:

```aro
Create the <a> with { name: "Alice", age: 30, city: "NYC" }.
Create the <b> with { name: "Alice", age: 25 }.

Compute the <result: difference> from <a> with <b>.
(* result = { age: 30, city: "NYC" } *)
(* 'name' matches, 'age' differs, 'city' only in A *)
```

### 5.4 Union

Merges objects, with A's values taking precedence for conflicts:

```aro
Create the <a> with { name: "Alice", role: "admin" }.
Create the <b> with { name: "Bob", email: "bob@example.com" }.

Compute the <result: union> from <a> with <b>.
(* result = { name: "Alice", role: "admin", email: "bob@example.com" } *)
(* A's 'name' wins over B's 'name' *)
```

---

## 6. Use Cases

### 6.1 Permission Comparison

```aro
(* Find permissions user has but shouldn't *)
Compute the <excess: difference> from <user-permissions> with <role-permissions>.

(* Find missing permissions *)
Compute the <missing: difference> from <required-permissions> with <user-permissions>.

(* Compute effective permissions *)
Compute the <effective: intersect> from <requested-permissions> with <allowed-permissions>.
```

### 6.2 Data Deduplication

```aro
(* Merge two lists removing duplicates *)
Compute the <all-items: union> from <list-a> with <list-b>.

(* Find items in both sources *)
Compute the <duplicates: intersect> from <source-a> with <source-b>.
```

### 6.3 Configuration Merging

```aro
(* Merge config with defaults (config wins) *)
Compute the <final-config: union> from <user-config> with <default-config>.

(* Find customized settings *)
Compute the <customized: difference> from <user-config> with <default-config>.
```

### 6.4 Tag Operations

```aro
(* Find common tags *)
Compute the <common-tags: intersect> from <article-tags> with <filter-tags>.

(* Find unique tags for article *)
Compute the <unique-tags: difference> from <article-tags> with <common-tags>.

(* Combine all tags *)
Compute the <all-tags: union> from <existing-tags> with <new-tags>.
```

---

## 7. Operation Summary

| Operation | Lists | Strings | Objects |
|-----------|-------|---------|---------|
| **intersect** | Elements in both (multiset) | Characters in both | Keys with matching values |
| **difference** | A minus B (multiset) | A chars not in B | Keys not matching in B |
| **union** | Unique elements from both | A + unique chars from B | Merged (A wins conflicts) |
| **symmetric-difference** | In exactly one (multiset) | Chars in exactly one | Keys differing between the two |
| **`subset of`** *(predicate)* | Every element present | Every character present | Every key present with an equal value |

---

## 8. Comparison with Other Languages

| ARO | Python | JavaScript | SQL |
|-----|--------|------------|-----|
| `intersect` | `set(a) & set(b)` | `a.filter(x => b.includes(x))` | `INTERSECT` |
| `difference` | `set(a) - set(b)` | `a.filter(x => !b.includes(x))` | `EXCEPT` |
| `symmetric-difference` | `set(a) ^ set(b)` | — | `(A EXCEPT B) UNION (B EXCEPT A)` |
| `subset of` | `set(a) <= set(b)` | `a.every(x => b.includes(x))` | `NOT EXISTS (A EXCEPT B)` |
| `union` | `set(a) \| set(b)` | `[...new Set([...a, ...b])]` | `UNION` |

---

## Implementation

### 8.1 ComputeAction Extension

```swift
case "intersect":
    guard let secondOperand = context.resolveAny("_with_") else {
        throw ActionError.runtimeError("Intersect requires a 'with' clause")
    }
    return try computeIntersect(input, with: secondOperand)

case "difference":
    guard let secondOperand = context.resolveAny("_with_") else {
        throw ActionError.runtimeError("Difference requires a 'with' clause")
    }
    return try computeDifference(input, minus: secondOperand)

case "union":
    guard let secondOperand = context.resolveAny("_with_") else {
        throw ActionError.runtimeError("Union requires a 'with' clause")
    }
    return try computeUnion(input, with: secondOperand)
```

### 8.2 Type-Specific Implementations

```swift
/// Multiset intersection for arrays
private func multisetIntersect(_ a: [any Sendable], _ b: [any Sendable]) -> [any Sendable]

/// Character intersection for strings
private func stringIntersect(_ a: String, _ b: String) -> String

/// Deep recursive intersection for objects
private func intersectDictionaries(
    _ a: [String: any Sendable],
    _ b: [String: any Sendable]
) -> [String: any Sendable]
```

---

## Summary

| Operation | Syntax | Description |
|-----------|--------|-------------|
| **Intersect** | `Compute the <r: intersect> from <a> with <b>.` | Elements in both |
| **Difference** | `Compute the <r: difference> from <a> with <b>.` | Elements in A not in B |
| **Union** | `Compute the <r: union> from <a> with <b>.` | All unique elements |

---

## References

- `Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift` - Implementation
- `Examples/SetOperations/` - Set operation examples
- ARO-0004: Actions - Compute action
