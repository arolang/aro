# ARO-0038: List Element Access Specifiers

* Proposal: ARO-0038
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002

## Abstract

This proposal defines result specifiers for accessing specific elements from lists and arrays. Specifiers enable extracting the first, last, indexed, or ranged elements without explicit iteration.

---

## 1. Keyword Specifiers

### 1.1 First Element

```aro
Extract the <item: first> from the <list>.
```

Returns the first element of the list.

### 1.2 Last Element

```aro
Extract the <item: last> from the <list>.
```

Returns the last element of the list.

### 1.3 Examples

```aro
Create the <numbers> with [10, 20, 30, 40, 50].

Extract the <first-num: first> from the <numbers>.
(* first-num = 10 *)

Extract the <last-num: last> from the <numbers>.
(* last-num = 50 *)
```

---

## 2. Numeric Index Access

### 2.1 Reverse Indexing

Numeric indices use **reverse indexing** where `0` is the last element:

| Index | Position |
|-------|----------|
| `0` | Last element |
| `1` | Second-to-last |
| `2` | Third-to-last |
| `n` | Element at (count - 1 - n) |

### 2.2 Syntax

```aro
Extract the <item: 0> from the <list>.   (* Last element *)
Extract the <item: 1> from the <list>.   (* Second-to-last *)
Extract the <item: 2> from the <list>.   (* Third-to-last *)
```

### 2.3 Examples

```aro
Create the <items> with ["a", "b", "c", "d", "e"].

Extract the <e0: 0> from the <items>.  (* "e" - last *)
Extract the <e1: 1> from the <items>.  (* "d" - second-to-last *)
Extract the <e2: 2> from the <items>.  (* "c" - third-to-last *)
```

### 2.4 Rationale for Reverse Indexing

Reverse indexing is common for accessing recent elements:
- `0` = most recent / latest / last
- Works naturally with logs, stacks, and queues
- Mirrors common "tail" operations

---

## 3. Range Specifiers

### 3.1 Syntax

```aro
Extract the <subset: start-end> from the <list>.
```

Returns elements from index `start` to `end` (inclusive), using reverse indexing.

### 3.2 Examples

```aro
Create the <items> with ["a", "b", "c", "d", "e"].

(* Elements 2-4 from the end: "c", "d", "e" *)
Extract the <recent: 0-2> from the <items>.
(* recent = ["c", "d", "e"] *)

(* Elements 1-3 from the end: "b", "c", "d" *)
Extract the <middle: 1-3> from the <items>.
(* middle = ["b", "c", "d"] *)
```

---

## 4. Pick Specifiers

### 4.1 Syntax

Select specific elements by their indices:

```aro
Extract the <selection: i1,i2,i3> from the <list>.
```

### 4.2 Examples

```aro
Create the <items> with ["a", "b", "c", "d", "e"].

(* Pick elements at reverse indices 0, 2, 4 *)
Extract the <picked: 0,2,4> from the <items>.
(* picked = ["e", "c", "a"] *)
```

---

## 5. Use Cases

### 5.1 Path Manipulation

```aro
(* Get filename from path *)
Split the <parts> from the <path> by /\//.
Extract the <filename: last> from the <parts>.

(* Get parent directory *)
Extract the <parent: 1> from the <parts>.
```

### 5.2 Log Analysis

```aro
(* Get most recent log entries *)
Retrieve the <logs> from the <log-repository>.
Extract the <recent-logs: 0-9> from the <logs>.
(* Gets last 10 entries *)
```

### 5.3 CSV Field Extraction

```aro
Split the <fields> from the <csv-line> by /,/.
Extract the <name: first> from the <fields>.
Extract the <id: last> from the <fields>.
```

### 5.4 Stack Operations

```aro
(* Peek at top of stack *)
Extract the <top: 0> from the <stack>.

(* Get top 3 items *)
Extract the <top-three: 0-2> from the <stack>.
```

---

## 6. Behavior

### 6.1 Out of Bounds

Accessing an index beyond the list length returns `nil`:

```aro
Create the <short> with [1, 2].
Extract the <item: 5> from the <short>.
(* item = nil *)
```

### 6.2 Empty Lists

Accessing elements from an empty list returns `nil`:

```aro
Create the <empty> with [].
Extract the <first: first> from the <empty>.
(* first = nil *)
```

### 6.3 Range Clamping

Ranges are clamped to list bounds:

```aro
Create the <short> with [1, 2, 3].
Extract the <range: 0-10> from the <short>.
(* range = [1, 2, 3] - clamped to available elements *)
```

---

## 7. Specifier Types Summary

| Specifier | Type | Returns | Example |
|-----------|------|---------|---------|
| `first` | Keyword | Single element | `<x: first>` |
| `last` | Keyword | Single element | `<x: last>` |
| `0` | Index | Single element | `<x: 0>` (last) |
| `n` | Index | Single element | `<x: 3>` |
| `0-5` | Range | List | `<x: 0-5>` |
| `0,2,4` | Pick | List | `<x: 0,2,4>` |

---

## Grammar Extension

```ebnf
result_specifier = "first" | "last" | index | range | pick ;
index = digit+ ;
range = index , "-" , index ;
pick = index , { "," , index } ;

qualified_result = "<" , identifier , [ ":" , result_specifier ] , ">" ;
```

---

## Summary

| Specifier | Description | Result Type |
|-----------|-------------|-------------|
| `first` | First element | Single |
| `last` | Last element | Single |
| `0` | Last element (reverse index) | Single |
| `n` | Element at reverse index n | Single |
| `n-m` | Range of elements | List |
| `a,b,c` | Pick specific elements | List |

---

## References

- `Sources/AROParser/AST.swift` - ResultDescriptor with specifiers
- ARO-0002: Control Flow - Iteration and element access
- ARO-0037: Regex Split - Often used with element access
