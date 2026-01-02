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
[Application-Start] === ARO Calculator Demo ===
[Application-Start] 15 + 7 =
[Application-Start] 22
[Application-Start] 25 - 10 =
[Application-Start] 15
[Application-Start] 6 * 8 =
[Application-Start] 48
[Application-Start] 100 / 4 =
[Application-Start] 25
[Application-Start] Shopping cart: 3 items @ $50 each
[Application-Start] Subtotal: $
[Application-Start] 150
[Application-Start] Tax (8%): $
[Application-Start] 12.00
[Application-Start] Total: $
[Application-Start] 162.00
[Application-Start] === Calculator Demo Complete ===
```

---

*Simple arithmetic operations demonstrating ARO's expression evaluation and computation capabilities.*
