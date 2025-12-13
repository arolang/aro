# Calculator

A calculator with built-in tests demonstrating ARO's BDD-style testing framework.

## What It Does

Provides basic arithmetic operations (add, subtract, multiply) as feature sets that can be invoked programmatically, with companion test feature sets that verify correctness using Given/When/Then syntax.

## Features Tested

- **Testing framework** - Tests identified by "Test" suffix in business activity
- **BDD-style testing** - `<Given>`, `<When>`, `<Then>` actions for test setup and assertions
- **Expression evaluation** - Arithmetic expressions like `<a> + <b>`
- **Test stripping** - Production builds exclude test feature sets

## Related Proposals

- [ARO-0015: Testing Framework](../../Proposals/ARO-0015-testing-framework.md)
- [ARO-0002: Expressions](../../Proposals/ARO-0002-expressions.md)

## Usage

```bash
# Run tests
aro test ./Examples/Calculator

# Build production binary (strips tests)
aro build ./Examples/Calculator
```

## Example Output

```
PASS add-positive-numbers
PASS add-zero
PASS subtract-basic
PASS multiply-basic

4 tests passed, 0 failed
```

---

*Tests live alongside production code, not in separate files. The boundary between specification and implementation dissolves when both speak the same language.*
