# ARO-0042: Polymorphic Set Operations

- **Status**: Draft
- **Discussion**: https://github.com/arolang/aro/discussions/97
- **Author**: Claude (with KrisSimon)
- **Created**: 2025-12-30

## Summary

This proposal adds three polymorphic set operations (`intersect`, `difference`, `union`) to ARO's Compute action. These operations work uniformly across Lists, Strings, and deep nested Objects, following the existing computation pattern established by operations like `length`, `uppercase`, and `hash`.

Additionally, this proposal enhances the Filter action with `not in` operator support and the ability to use arrays (not just CSV strings) for membership testing.

## Motivation

Given two lists:
```aro
<Create> the <list-a> with [2, 3, 5].
<Create> the <list-b> with [1, 2, 3, 4].
```

Users currently have no way to compute:
- **Intersection**: `[2, 3]` (elements in both)
- **Difference A-B**: `[5]` (elements in A but not B)
- **Difference B-A**: `[1, 4]` (elements in B but not A)
- **Union**: `[2, 3, 5, 1, 4]` (all unique elements)

These are fundamental operations needed for data processing, configuration merging, permission checking, and many other common tasks.

## Design Decisions

After evaluating three approaches (see Discussion section), the following decisions were made:

### Approach: Compute Operations (Not New Actions)

Set operations are implemented as **Compute operations** rather than new action verbs because:

1. **Conceptual correctness**: Set operations are transformations on data, not interactions with the world. In ARO's philosophy:
   - **Actions** = verbs that interact with the world (Extract, Store, Send, Return)
   - **Compute** = transformations on data (length, hash, uppercase, intersect)

2. **Consistency**: Other transformations (`length`, `uppercase`, `hash`) are Compute operations, not separate actions.

3. **Plugin simplicity**: Plugins can extend via `ComputationService` protocol instead of implementing full `ActionImplementation`.

4. **No verb proliferation**: ARO already has 50+ verbs; adding more increases the learning curve.

### Decisions from Discussion

| Question | Decision |
|----------|----------|
| Should `union` deduplicate? | **Yes** - deduplicate by default |
| String character order? | **Preserve order** from the first operand |
| Include `symmetric-difference`? | **No** - leave to plugins as example |
| Duplicate handling in lists? | **Multiset semantics** - preserve duplicates up to minimum count |

## Proposed Syntax

### Set Operations via Compute

```aro
(* Intersection: elements in both *)
<Compute> the <common: intersect> from <list-a> with <list-b>.

(* Difference: elements in first but not second *)
<Compute> the <only-in-a: difference> from <list-a> with <list-b>.

(* Union: all unique elements *)
<Compute> the <all: union> from <list-a> with <list-b>.
```

### Enhanced Filter Operators

```aro
(* Membership testing with arrays *)
<Filter> the <included> from <items> where <value> in <list>.
<Filter> the <excluded> from <items> where <value> not in <list>.
```

## Type Behavior

### Lists

```aro
<Create> the <a> with [2, 3, 5].
<Create> the <b> with [1, 2, 3, 4].

<Compute> the <common: intersect> from <a> with <b>.    (* [2, 3] *)
<Compute> the <diff: difference> from <a> with <b>.     (* [5] *)
<Compute> the <all: union> from <a> with <b>.           (* [2, 3, 5, 1, 4] *)
```

**Duplicate handling (multiset semantics):**
```aro
<Create> the <a> with [1, 2, 2, 3].
<Create> the <b> with [2, 2, 2, 4].
<Compute> the <result: intersect> from <a> with <b>.    (* [2, 2] *)
```

### Strings

Operations work at the character level, preserving order from the first operand:

```aro
<Compute> the <shared: intersect> from "hello" with "bello".   (* "ello" *)
<Compute> the <unique: difference> from "hello" with "bello".  (* "h" *)
<Compute> the <all: union> from "hello" with "bello".          (* "helob" *)
```

### Deep Objects

Operations recursively compare nested structures:

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

<Compute> the <diff: difference> from <obj-a> with <obj-b>.
(* Result: { age: 30, address: { zip: "10001" } } *)

<Compute> the <merged: union> from <obj-a> with <obj-b>.
(* Result: { name: "Alice", age: 30, address: { city: "NYC", zip: "10001", state: "NY" } } *)
(* Note: A wins on conflicts (age: 30 from A, not 31 from B) *)
```

## Type Behavior Matrix

| Operation | Lists | Strings | Objects |
|-----------|-------|---------|---------|
| **intersect** | Elements in both (multiset) | Chars in both (order preserved) | Keys with matching values (recursive) |
| **difference** | In A, not in B | Chars in A, not in B | Keys/values in A, not in B |
| **union** | All unique elements | All unique chars | Merge all keys (A wins conflicts) |

## Edge Cases

### Type Mismatches
```aro
<Create> the <a> with { value: 42 }.
<Create> the <b> with { value: "42" }.
<Compute> the <result: intersect> from <a> with <b>.
(* Result: {} - strict type equality, 42 !== "42" *)
```

### Null vs Missing Keys
```aro
<Create> the <a> with { name: "Alice", age: null }.
<Create> the <b> with { name: "Alice" }.
<Compute> the <result: intersect> from <a> with <b>.
(* Result: { name: "Alice" } - null in A with missing in B = no match *)
```

### Empty Collections
```aro
<Create> the <a> with { items: [] }.
<Create> the <b> with { items: [] }.
<Compute> the <result: intersect> from <a> with <b>.
(* Result: { items: [] } - empty arrays are equal *)
```

### Arrays Within Objects
```aro
<Create> the <a> with { tags: ["a", "b"] }.
<Create> the <b> with { tags: ["b", "a"] }.
<Compute> the <result: intersect> from <a> with <b>.
(* Result: { tags: ["a", "b"] } - arrays use set intersection (order-independent) *)
```

### Unicode (Strings)
```aro
<Compute> the <result: intersect> from "café" with "cafe".
(* Uses Swift's Character comparison (grapheme clusters) *)
(* "é" as single char matches "é" as composed *)
```

### Case Sensitivity (Strings)
```aro
<Compute> the <result: intersect> from "Hello" with "hello".
(* Result: "ello" - case-sensitive by default *)
```

### Mixed Types in Lists
```aro
<Create> the <a> with [1, "1", true].
<Create> the <b> with [1, "1", 1].
<Compute> the <result: intersect> from <a> with <b>.
(* Result: [1, "1"] - strict type equality, true !== 1 *)
```

### Nested Objects in Lists
```aro
<Create> the <a> with [{ id: 1, name: "Alice" }, { id: 2, name: "Bob" }].
<Create> the <b> with [{ id: 1, name: "Alice" }, { id: 3, name: "Charlie" }].
<Compute> the <result: intersect> from <a> with <b>.
(* Result: [{ id: 1, name: "Alice" }] - deep recursive comparison for objects *)
```

### Circular References
```aro
(* If circular structures are ever supported *)
<Create> the <a> with { self: <a> }.
(* Throws error - cycles detected to prevent infinite recursion *)
```

### Edge Case Summary

| Edge Case | Behavior |
|-----------|----------|
| Type mismatch at key | No match (strict equality) |
| `null` vs missing key | No match |
| Empty arrays/objects | Equal (include in result) |
| Array order in objects | Order-independent (set intersection) |
| Circular references | Throw error |
| Deep nesting | No arbitrary limit |
| Unicode | Grapheme cluster comparison |
| Case sensitivity | Case-sensitive |
| Empty operand | Empty result |
| Duplicates in lists | Multiset (preserve up to min count) |
| Mixed types in lists | Strict type equality |
| Nested objects in lists | Deep recursive comparison |

## Filter Enhancement

### New `not in` Operator

```aro
<Filter> the <excluded> from <items> where <status> not in "active,pending".
<Filter> the <excluded> from <items> where <value> not in <exclude-list>.
```

### Array Support for `in`/`not in`

Currently, Filter's `in` operator only accepts CSV strings:
```aro
(* Current - CSV string only *)
<Filter> the <x> from <items> where <v> in "1,2,3".
```

Enhanced to accept arrays:
```aro
(* Enhanced - accepts arrays *)
<Create> the <valid-ids> with [1, 2, 3].
<Filter> the <x> from <items> where <id> in <valid-ids>.
<Filter> the <y> from <items> where <id> not in <valid-ids>.
```

## Implementation

### Architecture: Protocol-Based Generics

This implementation uses **Swift protocols with generic constraints** instead of runtime type checking. This provides better type safety, code reusability, and extensibility.

### ComputeAction.swift Changes

Add to known computations:
```swift
let knownComputations: Set<String> = [
    "hash", "length", "count", "uppercase", "lowercase", "identity",
    "date", "format", "distance",
    "intersect", "difference", "union"  // NEW
]
```

Add operation dispatch:
```swift
case "intersect":
    return try computeIntersect(input, with: secondOperand)
case "difference":
    return try computeDifference(input, from: secondOperand)
case "union":
    return try computeUnion(input, with: secondOperand)
```

### Protocol Definition

Define a protocol for types that support set operations:

```swift
/// Types that can participate in set operations
protocol SetOperable: Sendable {
    /// Compute intersection with another value
    func intersect(with other: Self) -> Self

    /// Compute difference (self - other)
    func difference(from other: Self) -> Self

    /// Compute union with another value
    func union(with other: Self) -> Self
}
```

### Generic Dispatcher Functions

Use generic functions with protocol constraints instead of runtime type checking:

```swift
// Entry points that handle type erasure (any Sendable -> concrete type)
private func computeIntersect(_ a: Any, with b: Any) throws -> any Sendable {
    if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
        return arrA.intersect(with: arrB)
    }
    if let strA = a as? String, let strB = b as? String {
        return strA.intersect(with: strB)
    }
    if let dictA = a as? [String: any Sendable],
       let dictB = b as? [String: any Sendable] {
        return dictA.intersect(with: dictB)
    }
    throw ActionError.typeMismatch(
        expected: "Array, String, or Dictionary",
        actual: String(describing: type(of: a))
    )
}

private func computeDifference(_ a: Any, from b: Any) throws -> any Sendable {
    if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
        return arrA.difference(from: arrB)
    }
    if let strA = a as? String, let strB = b as? String {
        return strA.difference(from: strB)
    }
    if let dictA = a as? [String: any Sendable],
       let dictB = b as? [String: any Sendable] {
        return dictA.difference(from: dictB)
    }
    throw ActionError.typeMismatch(
        expected: "Array, String, or Dictionary",
        actual: String(describing: type(of: a))
    )
}

private func computeUnion(_ a: Any, with b: Any) throws -> any Sendable {
    if let arrA = a as? [any Sendable], let arrB = b as? [any Sendable] {
        return arrA.union(with: arrB)
    }
    if let strA = a as? String, let strB = b as? String {
        return strA.union(with: strB)
    }
    if let dictA = a as? [String: any Sendable],
       let dictB = b as? [String: any Sendable] {
        return dictA.union(with: dictB)
    }
    throw ActionError.typeMismatch(
        expected: "Array, String, or Dictionary",
        actual: String(describing: type(of: a))
    )
}
```

### Type-Specific Conformances

Implement the `SetOperable` protocol for each supported type using extensions:

#### Array Extension

```swift
extension Array: SetOperable where Element == any Sendable {
    func intersect(with other: Array<Element>) -> Array<Element> {
        // Multiset intersection - preserve duplicates up to minimum count
        var otherCounts: [String: (Element, Int)] = [:]
        for item in other {
            let key = hashKey(item)
            let current = otherCounts[key]?.1 ?? 0
            otherCounts[key] = (item, current + 1)
        }

        var result: [Element] = []
        for item in self {
            let key = hashKey(item)
            if let (_, count) = otherCounts[key], count > 0 {
                result.append(item)
                otherCounts[key]?.1 -= 1
            }
        }
        return result
    }

    func difference(from other: Array<Element>) -> Array<Element> {
        let otherSet = Set(other.map { hashKey($0) })
        return self.filter { !otherSet.contains(hashKey($0)) }
    }

    func union(with other: Array<Element>) -> Array<Element> {
        var seen: Set<String> = []
        var result: [Element] = []

        for item in self + other {
            let key = hashKey(item)
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }
        return result
    }

    // Helper to generate hash keys for elements
    private func hashKey(_ item: Element) -> String {
        // Use stable hashing for all types (primitives, arrays, objects)
        // Implementation details omitted for brevity
        return generateHashKey(for: item)
    }
}
```

#### String Extension

```swift
extension String: SetOperable {
    func intersect(with other: String) -> String {
        let otherSet = Set(other)
        return String(self.filter { otherSet.contains($0) })
    }

    func difference(from other: String) -> String {
        let otherSet = Set(other)
        return String(self.filter { !otherSet.contains($0) })
    }

    func union(with other: String) -> String {
        var seen: Set<Character> = []
        var result: [Character] = []

        for char in self + other {
            if !seen.contains(char) {
                seen.insert(char)
                result.append(char)
            }
        }
        return String(result)
    }
}
```

#### Dictionary Extension

```swift
extension Dictionary: SetOperable where Key == String, Value == any Sendable {
    func intersect(with other: Dictionary<String, Value>) -> Dictionary<String, Value> {
        var result: [String: Value] = [:]

        for (key, valueA) in self {
            guard let valueB = other[key] else { continue }

            // Recursive for nested dictionaries
            if let nestedA = valueA as? [String: any Sendable],
               let nestedB = valueB as? [String: any Sendable] {
                let nested = nestedA.intersect(with: nestedB)
                if !nested.isEmpty {
                    result[key] = nested as? Value
                }
            }
            // Arrays within objects
            else if let arrA = valueA as? [any Sendable],
                    let arrB = valueB as? [any Sendable] {
                let intersected = arrA.intersect(with: arrB)
                if !intersected.isEmpty {
                    result[key] = intersected as? Value
                }
            }
            // Primitive equality
            else if areStrictlyEqual(valueA, valueB) {
                result[key] = valueA
            }
        }
        return result
    }

    func difference(from other: Dictionary<String, Value>) -> Dictionary<String, Value> {
        var result: [String: Value] = [:]

        for (key, valueA) in self {
            if let valueB = other[key] {
                // Deep comparison for nested structures
                if !areStrictlyEqual(valueA, valueB) {
                    result[key] = valueA
                }
            } else {
                result[key] = valueA
            }
        }
        return result
    }

    func union(with other: Dictionary<String, Value>) -> Dictionary<String, Value> {
        var result = self  // A wins on conflicts

        for (key, valueB) in other {
            if result[key] == nil {
                result[key] = valueB
            }
            // Recursive merge for nested dictionaries
            else if let nestedA = result[key] as? [String: any Sendable],
                    let nestedB = valueB as? [String: any Sendable] {
                result[key] = nestedA.union(with: nestedB) as? Value
            }
        }
        return result
    }
}
```

### Benefits of Generic Approach

1. **Type Safety**: Compile-time checking instead of runtime casting
2. **Code Reuse**: Each operation (intersect/difference/union) implemented once per type
3. **Extensibility**: New types just conform to `SetOperable` protocol
4. **Performance**: No repeated type checking at runtime
5. **Maintainability**: Single source of truth for each operation
6. **Testability**: Protocol conformances can be tested independently
7. **Swift 6.2 Concurrency**: All types are `Sendable`, ensuring thread safety

### Alternative: Protocol with Associated Types

For even more type safety, an alternative design using associated types could be considered:

```swift
protocol SetOperable {
    associatedtype Element

    func intersect(with other: Self) -> Self
    func difference(from other: Self) -> Self
    func union(with other: Self) -> Self
}

// Generic function with where clause
func performSetOperation<T>(
    _ a: T,
    _ b: T,
    operation: (T, T) -> T
) -> T where T: SetOperable {
    return operation(a, b)
}
```

However, this approach is more complex and the simpler `Self` constraint is sufficient for this use case.

### QueryActions.swift Changes (Filter)

```swift
case "in":
    // Support array values
    if let arr = expected as? [any Sendable] {
        return arr.contains { areStrictlyEqual($0, actual) }
    }
    // Fallback to CSV string parsing
    let values = expectedStr.split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    return values.contains(actualStr)

case "not in", "not-in":
    if let arr = expected as? [any Sendable] {
        return !arr.contains { areStrictlyEqual($0, actual) }
    }
    let values = expectedStr.split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
    return !values.contains(actualStr)
```

## Plugin Extensibility

The existing `ComputationService` protocol allows plugins to add custom set operations:

```swift
public struct CustomSetOperations: ComputationService {
    public func compute(named: String, input: Any) async throws -> any Sendable {
        switch named {
        case "symmetric-difference":
            // A XOR B = (A - B) ∪ (B - A)
            guard let (a, b) = extractOperands(input) else {
                throw ActionError.typeMismatch(...)
            }
            let aMinusB = difference(a, b)
            let bMinusA = difference(b, a)
            return union(aMinusB, bMinusA)
        default:
            throw ActionError.unknownOperation(named)
        }
    }
}

// Register at startup
context.register(CustomSetOperations())
```

Usage:
```aro
<Compute> the <sym-diff: symmetric-difference> from <a> with <b>.
```

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift` | Add intersect/difference/union operations |
| `Sources/ARORuntime/Actions/BuiltIn/QueryActions.swift` | Add `not in` operator, array support for `in` |

## Files to Create

| File | Purpose |
|------|---------|
| `Examples/SetOperations/main.aro` | Demo showing all set operations |
| `Examples/SymmetricDifference/main.aro` | Plugin example for symmetric-difference |

## Complete Example

```aro
(Application-Start: Set Operations Demo) {
    <Log> the <h> for the <console> with "=== ARO Set Operations Demo ===".

    (* === LISTS === *)
    <Create> the <list-a> with [2, 3, 5].
    <Create> the <list-b> with [1, 2, 3, 4].

    <Compute> the <common: intersect> from <list-a> with <list-b>.
    <Log> the <r> for the <console> with "Intersection: ".
    <Log> the <r> for the <console> with <common>.

    <Compute> the <only-a: difference> from <list-a> with <list-b>.
    <Log> the <r> for the <console> with "A - B: ".
    <Log> the <r> for the <console> with <only-a>.

    <Compute> the <only-b: difference> from <list-b> with <list-a>.
    <Log> the <r> for the <console> with "B - A: ".
    <Log> the <r> for the <console> with <only-b>.

    <Compute> the <all: union> from <list-a> with <list-b>.
    <Log> the <r> for the <console> with "Union: ".
    <Log> the <r> for the <console> with <all>.

    (* === DUPLICATES (Multiset) === *)
    <Create> the <dup-a> with [1, 2, 2, 3].
    <Create> the <dup-b> with [2, 2, 2, 4].
    <Compute> the <dup-result: intersect> from <dup-a> with <dup-b>.
    <Log> the <r> for the <console> with "Multiset intersection: ".
    <Log> the <r> for the <console> with <dup-result>.

    (* === STRINGS === *)
    <Compute> the <shared-chars: intersect> from "hello" with "bello".
    <Log> the <r> for the <console> with "String intersection: ".
    <Log> the <r> for the <console> with <shared-chars>.

    (* === DEEP OBJECTS === *)
    <Create> the <obj-a> with {
        name: "Alice",
        address: { city: "NYC", zip: "10001" }
    }.
    <Create> the <obj-b> with {
        name: "Alice",
        address: { city: "NYC", state: "NY" }
    }.

    <Compute> the <common-obj: intersect> from <obj-a> with <obj-b>.
    <Log> the <r> for the <console> with "Object intersection: ".
    <Log> the <r> for the <console> with <common-obj>.

    (* === FILTER WITH NOT IN === *)
    <Create> the <items> with [
        {id: 1, value: 2},
        {id: 2, value: 3},
        {id: 3, value: 5}
    ].
    <Create> the <exclude> with [3, 5].

    <Filter> the <excluded> from <items> where <value> not in <exclude>.
    <Log> the <r> for the <console> with "Items not in exclude list: ".
    <Log> the <r> for the <console> with <excluded>.

    <Return> an <OK: status> for the <demo>.
}
```

## Alternatives Considered

### Alternative 1: New Actions (Rejected)

```aro
<Intersect> the <common> from <list-a> with <list-b>.
<Difference> the <only-in-a> from <list-a> with <list-b>.
<Union> the <all> from <list-a> with <list-b>.
```

**Rejected because:**
- Adds 3 new verbs to ARO's already large verb set
- Inconsistent with how other transformations (length, hash) are implemented
- More complex plugin API (ActionImplementation vs ComputationService)
- Treats transformations as actions, which is conceptually incorrect

### Alternative 2: Filter-Only (Rejected as Complete Solution)

```aro
<Filter> the <common> from <list-a> where <value> in <list-b>.
```

**Rejected because:**
- Only works with object arrays (requires field access)
- Cannot work on primitive arrays directly
- Cannot handle strings
- Cannot do deep object comparison
- `not in` was missing (now added as enhancement)

However, Filter enhancement is **included** as a secondary feature for membership testing in object arrays.

## Performance Characteristics

### Time Complexity

| Operation | List | String | Object |
|-----------|------|--------|--------|
| `intersect` | O(n*m) multiset | O(n+m) | O(n*m*d) where d=depth |
| `difference` | O(n*m) | O(n+m) | O(n*m*d) |
| `union` | O(n+m) | O(n+m) | O(n*m*d) |

### Memory Usage

- **Lists**: O(min(n,m)) for intersection, O(n+m) for union
- **Strings**: O(n+m) for character counting
- **Objects**: O(depth * keys) for recursive comparison

### Recursion Depth

Deep nesting is supported without arbitrary limits. However, extremely deep structures (>1000 levels) may cause stack overflow. Consider restructuring data if deep nesting is required.

### Best Practices

- For large lists (>10000 items), prefer database-level set operations
- String operations are optimized for typical text lengths (<10KB)
- Object operations perform best with shallow structures (<10 levels)

## Future Considerations

1. **Case-insensitive string operations**: Could add `intersect-ci` variant
2. **Custom equality functions**: Allow users to specify comparison logic
3. **Sorted output**: Option to sort union/intersection results
4. **Performance optimization**: Lazy evaluation for large collections
5. **Configurable depth limit**: Runtime-configurable recursion limit for deep structures
6. **Streaming operations**: Memory-efficient processing for very large collections

## References

- [Discussion #97](https://github.com/arolang/aro/discussions/97) - RFC discussion with design decisions
- [ARO-0035](./ARO-0035-qualifier-as-name.md) - Qualifier-as-name syntax for Compute operations
- [ARO-0018](./ARO-0018-query-language.md) - Data pipelines (Filter, Map, Reduce)
