# Conditionals

Demonstrates conditional branching with guarded statements and match expressions.

## What It Does

Shows how to route logic based on variable values using `when` clauses for inline guards and `match` blocks for multi-way branching. Routes HTTP methods and status codes as practical examples.

## Features Tested

- **Guarded statements** - `when` clause for conditional execution
- **Match expressions** - Multi-way branching with `case` and `otherwise`
- **Comparison operators** - Equality checks with `==`
- **String and numeric matching** - Pattern matching on different value types

## Related Proposals

- [ARO-0004: Conditional Branching](../../Proposals/ARO-0004-conditional-branching.md)

## Usage

```bash
# Interpreted
aro run ./Examples/Conditionals

# Compiled
aro build ./Examples/Conditionals
./Examples/Conditionals/Conditionals
```

## Example Output

```
Admin access detected!
Handling POST request
Request successful
```

---

*Branching without nesting. The match expression replaces switch statements with something that reads like a decision table.*
