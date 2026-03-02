# ARO-0052: Numeric Separators

* Proposal: ARO-0052
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001

## Abstract

This proposal extends numeric literal syntax to allow underscore (`_`) characters as visual separators in decimal integer and floating-point literals. This feature improves readability of large numbers by allowing grouping of digits, consistent with existing support for underscores in hexadecimal and binary literals.

---

## 1. Motivation

### 1.1 Problem

Large numeric literals are difficult to read without visual grouping:

```aro
Create the <budget> with 1000000000.
Create the <population> with 7900000000.
Create the <pi-precise> with 3.14159265358979.
```

These numbers require mental effort to count digits and understand magnitude.

### 1.2 Solution

Underscore separators allow natural digit grouping:

```aro
Create the <budget> with 1_000_000_000.
Create the <population> with 7_900_000_000.
Create the <pi-precise> with 3.141_592_653_589_79.
```

The underscores are purely visual and do not affect the numeric value.

### 1.3 Consistency

ARO already supports underscores in hexadecimal and binary literals:

```aro
Create the <color> with 0xFF_FF_FF.
Create the <flags> with 0b1010_1010.
```

This proposal extends the same convenience to decimal literals.

---

## 2. Syntax

### 2.1 Integer Literals

```ebnf
integer_literal = [ "-" ] , digit , { digit | "_" , digit } ;
```

**Valid examples:**
```
1_000
1_000_000
1_000_000_000
123_456_789
```

**Invalid examples:**
```
_1000       (* Cannot start with underscore *)
1000_       (* Cannot end with underscore *)
1__000      (* Cannot have adjacent underscores *)
```

### 2.2 Floating-Point Literals

```ebnf
float_literal = [ "-" ] , integer_part , "." , fraction_part , [ exponent ] ;

integer_part  = digit , { digit | "_" , digit } ;
fraction_part = digit , { digit | "_" , digit } ;
exponent      = ( "e" | "E" ) , [ "+" | "-" ] , digit , { digit | "_" , digit } ;
```

**Valid examples:**
```
1_234.567_890
3.141_592_653
1_000.00
1e1_0
1.5e1_000
```

**Invalid examples:**
```
1_.5        (* Underscore cannot be adjacent to decimal point *)
1._5        (* Underscore cannot be adjacent to decimal point *)
1.5_e10     (* Underscore cannot be adjacent to exponent marker *)
1.5e_10     (* Underscore cannot be adjacent to exponent marker *)
```

---

## 3. Semantics

### 3.1 Value Equivalence

Underscores do not affect the numeric value:

| Literal | Value |
|---------|-------|
| `1_000_000` | 1000000 |
| `1000000` | 1000000 |
| `1_234.567_890` | 1234.56789 |
| `1234.56789` | 1234.56789 |

### 3.2 Grouping Freedom

Underscores can appear between any digits, not just at thousand separators:

```aro
(* All valid - grouping is flexible *)
Create the <binary-style> with 1111_0000_1111_0000.
Create the <phone-style> with 555_123_4567.
Create the <date-style> with 2024_01_15.
```

---

## 4. Implementation

### 4.1 Lexer Changes

The `scanNumber()` method in `Lexer.swift` is modified to:

1. Accept `_` characters between digits in the integer part
2. Accept `_` characters between digits after the decimal point
3. Accept `_` characters between digits in the exponent
4. Filter out underscores before parsing with `Int()` or `Double()`

### 4.2 Validation Rules

The lexer enforces:

- Underscore must be between two digits
- No leading underscores (before first digit)
- No trailing underscores (after last digit)
- No adjacent underscores
- No underscores adjacent to `.` or `e`/`E`

---

## 5. Examples

### 5.1 Financial Calculations

```aro
(Application-Start: Financial Demo) {
    Create the <principal> with 1_000_000.
    Create the <rate> with 0.05.
    Create the <years> with 10.

    Compute the <interest> from <principal> * <rate> * <years>.
    Log "Interest on $1,000,000: " to the <console>.
    Log <interest> to the <console>.

    Return an <OK: status> for the <demo>.
}
```

### 5.2 Scientific Notation

```aro
(Application-Start: Science Demo) {
    Create the <avogadro> with 6.022_140_76e23.
    Create the <planck> with 6.626_070_15e-34.

    Log "Avogadro's number: " to the <console>.
    Log <avogadro> to the <console>.

    Return an <OK: status> for the <demo>.
}
```

### 5.3 Large Integers

```aro
(Application-Start: Large Numbers) {
    Create the <billion> with 1_000_000_000.
    Create the <trillion> with 1_000_000_000_000.

    Log "One billion: " to the <console>.
    Log <billion> to the <console>.
    Log "One trillion: " to the <console>.
    Log <trillion> to the <console>.

    Return an <OK: status> for the <demo>.
}
```

---

## 6. Comparison with Other Languages

| Language | Syntax | Example |
|----------|--------|---------|
| ARO | `_` separator | `1_000_000` |
| Swift | `_` separator | `1_000_000` |
| Rust | `_` separator | `1_000_000` |
| Python | `_` separator | `1_000_000` |
| Java | `_` separator | `1_000_000` |
| JavaScript | `_` separator | `1_000_000` |

ARO follows the widely-adopted convention of using underscores as numeric separators.

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Purpose** | Improve readability of large numeric literals |
| **Syntax** | Underscore (`_`) between digits |
| **Scope** | Decimal integers, floats, and exponents |
| **Semantics** | Purely visual, no effect on value |
| **Consistency** | Matches existing hex/binary underscore support |

---

## References

- `Sources/AROParser/Lexer.swift` - Lexer implementation
- `Tests/AROParserTests/LexerTests.swift` - Unit tests
- `Examples/NumericSeparators/` - Example usage
- ARO-0001: Language Fundamentals - Number literal syntax
