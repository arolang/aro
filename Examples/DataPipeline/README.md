# DataPipeline

Demonstrates data pipeline operations for filtering, mapping, and aggregating collections.

## What It Does

Processes arrays of numbers and objects through pipeline operations: filters active orders, reduces collections to aggregates (sum, count, avg, min, max), and demonstrates field-level aggregations on object arrays.

## Features Tested

- **Filter action** - `<Filter>` with `where` clause for predicate-based selection
- **Reduce action** - Aggregations: `count()`, `sum()`, `avg()`, `min()`, `max()`
- **Field aggregations** - `sum(<amount>)` for object property aggregation
- **Map action** - Collection transformation (pass-through demonstrated)
- **Numeric comparisons** - Filter with `>`, `<`, `==` operators
- **Array and object literals** - Complex nested data structures

## Related Proposals

- [ARO-0018: Data Pipeline Operations](../../Proposals/ARO-0018-data-pipeline.md)
- [ARO-0002: Expressions](../../Proposals/ARO-0002-expressions.md)

## Usage

```bash
# Interpreted
aro run ./Examples/DataPipeline

# Compiled
aro build ./Examples/DataPipeline
./Examples/DataPipeline/DataPipeline
```

## Example Output

```
=== Test 1: Simple Array Reduce ===
Numbers: [1, 2, 3, 4, 5]
Count: 5
Sum: 15
Average: 3.0
Min: 1
Max: 5

=== Test 2: Object Array with Filter ===
Active Orders: [{id: 1, ...}, {id: 3, ...}, {id: 5, ...}]
Active Orders Total: 900.0
Active Orders Count: 3
```

---

*Data flows through pipelines, not loops. Filter what you need, reduce to what matters.*
