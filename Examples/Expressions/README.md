# Expressions

Demonstrates literals, expressions, and operators in ARO.

## What It Does

Calculates a shopping cart total with tax using arithmetic expressions, concatenates strings to form a full name, and validates conditions using comparison and boolean operators. Shows all the basic building blocks for computation in ARO.

## Features Tested

- **Numeric literals** - Integers and decimals
- **Arithmetic operators** - `+`, `-`, `*`, `/`
- **String concatenation** - `++` operator
- **Collection literals** - Arrays `[1, 2, 3]` and objects `{key: value}`
- **Comparison operators** - `==` for equality
- **Boolean operators** - `and`, `or`
- **Compute action** - Expression evaluation and binding
- **Validate action** - Condition checking

## Related Proposals

- [ARO-0002: Expressions](../../Proposals/ARO-0002-expressions.md)

## Usage

```bash
# Interpreted
aro run ./Examples/Expressions

# Compiled
aro build ./Examples/Expressions
./Examples/Expressions/Expressions
```

## Example Output

```
Expression Demo
100
8.0
108.0
John Doe
```

---

*Expressions are the atoms of computation. Everything else is just moving them around.*
