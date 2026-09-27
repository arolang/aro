# Calculator

A simple calculator demonstrating arithmetic operations in ARO.

## What It Does

Demonstrates basic arithmetic operations using ARO's expression evaluation and computation features.

## Features Demonstrated

- **Arithmetic operations** - Addition, subtraction, multiplication, division
- **Expression evaluation** - Expressions like `<a> + <b>`
- **Compute action** - Computing results from expressions
- **Complex calculations** - Multi-step calculations (shopping cart with tax)

## Related Proposals

- [ARO-0001: Language Fundamentals](../../Proposals/ARO-0001-language-fundamentals.md)

## Usage

```bash
# Run the calculator
aro run ./Examples/Calculator

# Compile to native binary
aro build ./Examples/Calculator
./Examples/Calculator/Calculator
```

## Example Output

```
=== ARO Calculator Demo ===
15 + 7 =
22
25 - 10 =
15
6 * 8 =
48
100 / 4 =
25
Shopping cart: 3 items @ $50 each
Subtotal: $
150
Tax (8%): $
12.00
Total: $
162.00
=== Calculator Demo Complete ===
```

---

*Simple arithmetic operations demonstrating ARO's expression evaluation and computation capabilities.*
