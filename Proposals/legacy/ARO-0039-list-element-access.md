# ARO-0039: List Element Access

* Proposal: ARO-0039
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0032

## Abstract

This proposal extends the element access semantics from repositories (ARO-0032) to all Lists (arrays) in ARO. It enables accessing individual elements, ranges, and selections from any array using specifiers on the result descriptor.

## Motivation

ARO-0032 introduced powerful element access for repositories:
```aro
<Retrieve> the <item: last> from the <user-repository>.
<Retrieve> the <item: first> from the <user-repository>.
<Retrieve> the <item: 0> from the <user-repository>.
```

However, this syntax only works with repositories. When working with arrays from other sources (Split results, Create literals, computed collections), developers cannot use the same intuitive syntax:

```aro
(* Split returns an array, but we can't easily access elements *)
<Split> the <parts> from the <csv-line> by /,/.
(* No way to get just the last part! *)
```

This proposal extends element access to ALL lists, making ARO more consistent and powerful.

---

## 1. Element Access Syntax

Element access uses specifiers on the **result** descriptor (left side), not the object:

```aro
<Extract> the <result: specifier> from the <source>.
```

### 1.1 Keyword Access

| Specifier | Description | Example |
|-----------|-------------|---------|
| `first` | First element (oldest) | `<Extract> the <item: first> from the <list>.` |
| `last` | Last element (most recent) | `<Extract> the <item: last> from the <list>.` |

### 1.2 Numeric Index Access

Indices follow the ARO-0032 convention where 0 = last element (most recent):

| Index | Element |
|-------|---------|
| 0 | Last (most recent) |
| 1 | Second-to-last |
| 2 | Third-to-last |
| n | (count - 1 - n)th element |

```aro
<Extract> the <item: 0> from the <list>.   (* last element *)
<Extract> the <item: 1> from the <list>.   (* second-to-last *)
```

### 1.3 Range Access

Extract consecutive elements using `start-end` syntax:

```aro
<Extract> the <subset: 2-5> from the <list>.   (* elements 2, 3, 4, 5 *)
```

Returns an array of elements at the specified indices.

### 1.4 Pick Access

Extract specific elements by listing indices separated by commas:

```aro
<Extract> the <selection: 0,3,7> from the <list>.   (* elements at 0, 3, 7 *)
```

Returns an array of elements at the specified indices.

---

## 2. Examples

### Basic Element Access

```aro
(* Create a list *)
<Create> the <fruits> with ["apple", "banana", "cherry", "date", "elderberry"].

(* Access by keyword *)
<Extract> the <first-fruit: first> from the <fruits>.   (* "apple" *)
<Extract> the <last-fruit: last> from the <fruits>.     (* "elderberry" *)

(* Access by index (0 = last) *)
<Extract> the <recent: 0> from the <fruits>.    (* "elderberry" *)
<Extract> the <second: 1> from the <fruits>.    (* "date" *)
```

### Split String and Access Parts

```aro
(* Split CSV line *)
<Create> the <csv-line> with "name,email,phone,address".
<Split> the <fields> from the <csv-line> by /,/.

(* Access specific fields *)
<Extract> the <name: first> from the <fields>.      (* "name" *)
<Extract> the <address: last> from the <fields>.    (* "address" *)
<Extract> the <email: 2> from the <fields>.         (* second-to-last = "phone" *)
```

### Range Access

```aro
<Create> the <numbers> with [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].

(* Extract range *)
<Extract> the <middle: 3-6> from the <numbers>.   (* [7, 6, 5, 4] in reverse order *)
```

### Pick Access

```aro
<Create> the <letters> with ["a", "b", "c", "d", "e", "f", "g"].

(* Pick specific elements *)
<Extract> the <vowels: 0,2,4> from the <letters>.   (* ["g", "e", "c"] *)
```

---

## 3. Indexing Semantics

Following ARO-0032, all indices are **reverse-indexed** where 0 = last element:

```
Array: [A, B, C, D, E]
Index:  4  3  2  1  0
        ↑           ↑
      first       last
```

| Specifier | Maps to Array Index |
|-----------|---------------------|
| `first` | 0 (first element) |
| `last` | count - 1 (last element) |
| `0` | count - 1 (last element) |
| `1` | count - 2 |
| `n` | count - 1 - n |

This semantic aligns with the "most recent first" paradigm used in repositories, where index 0 always refers to the most recently added item.

---

## 4. Return Values

| Access Type | Returns |
|-------------|---------|
| Single element (first, last, numeric) | Single value or empty string if out of bounds |
| Range (3-5) | Array of elements |
| Pick (3,5,7) | Array of elements |

Out-of-bounds indices are silently ignored (return empty string for single access, skip in range/pick).

---

## 5. Implementation

The implementation requires updating `ExtractAction` to check `result.specifiers` when the source is an array:

```swift
if let array = source as? [any Sendable] {
    if let specifier = result.specifiers.first {
        switch specifier.lowercased() {
        case "last": return array.last ?? ""
        case "first": return array.first ?? ""
        default:
            // Handle range (3-5), pick (3,5,7), or single index
        }
    }
    return array  // No specifier = full array
}
```

---

## 6. Compatibility

This proposal:
- Extends existing repository semantics to all arrays
- Does not change existing behavior
- Uses result specifiers consistently with ARO-0032
- Maintains backward compatibility with existing Extract usage

---

## 7. Alternatives Considered

### 7.1 Object-side Specifiers
```aro
<Extract> the <item> from the <list: last>.  (* rejected *)
```
Rejected because ARO-0032 established result-side specifiers for element access.

### 7.2 Separate Action
```aro
<Get> the <item> at <index> from the <list>.  (* rejected *)
```
Rejected as it introduces unnecessary action proliferation.

### 7.3 Forward Indexing (0 = first)
Rejected to maintain consistency with ARO-0032's "most recent first" paradigm.
