# Iteration

Demonstrates `for each` loops with filtering, indexing, and nesting.

## What It Does

Iterates over collections of users and teams using various loop patterns: basic iteration, filtered iteration with `where` clause, indexed iteration with `at`, and nested loops for hierarchical data.

## Features Tested

- **Basic for-each** - `for each <item> in <collection>`
- **Filtered iteration** - `where <condition> is <value>` clause
- **Indexed iteration** - `at <index>` for position tracking
- **Nested loops** - Loops within loops for hierarchical data
- **Object property access** - `<user: name>` syntax in loops
- **Compute in loops** - Arithmetic on index values

## Related Proposals

- [ARO-0005: Iteration](../../Proposals/ARO-0005-iteration.md)

## Usage

```bash
# Interpreted
aro run ./Examples/Iteration

# Compiled
aro build ./Examples/Iteration
./Examples/Iteration/Iteration
```

## Example Output

```
=== Basic For-Each ===
Alice
Bob
Charlie
Diana

=== Filtered For-Each ===
Alice
Charlie
Diana

=== Indexed For-Each ===
1
2
3
4

=== Nested For-Each ===
Alpha
Alice
Bob
Beta
Charlie
Diana
```

---

*Loops that read like sentences. The filter is part of the loop declaration, not buried inside it.*
