# ARO-0056: Numeric Literal Underscores for Decimal Numbers

* Proposal: ARO-0056
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #98

## Abstract

Extend underscore separator support to decimal integer and floating-point literals, making ARO consistent with hexadecimal and binary literals and matching the conventions of modern programming languages.

## Motivation

ARO currently supports underscores in hexadecimal and binary literals for readability:

```aro
Compute the <color> from 0xFF_00_FF.     (* ✅ Works *)
Compute the <flags> from 0b1111_0000.    (* ✅ Works *)
```

However, decimal literals do not support underscores:

```aro
Compute the <million> from 1_000_000.    (* ❌ Syntax error! *)
Compute the <price> from 1_299.99.       (* ❌ Syntax error! *)
```

This inconsistency is confusing and makes large decimal numbers harder to read. Most modern languages support underscore separators in all numeric bases:

| Language | Support |
|----------|---------|
| Python | ✅ `1_000_000` |
| Rust | ✅ `1_000_000` |
| Java | ✅ `1_000_000` |
| Swift | ✅ `1_000_000` |
| JavaScript | ✅ `1_000_000` |
| C++ (C++14+) | ✅ `1'000'000` (apostrophe) |

## Proposed Solution

Allow underscores in decimal integer and floating-point literals, matching the existing hex/binary implementation.

### Examples

```aro
(* Decimal integers *)
Compute the <million> from 1_000_000.
Compute the <billion> from 1_000_000_000.

(* Floating-point *)
Compute the <price> from 1_299.99.
Compute the <pi> from 3.141_592_653_589_793.
Compute the <sci> from 6.022_141_5e23.

(* Works everywhere underscores make sense *)
Compute the <big> from 999_999_999.
```

### Rules

1. **Underscores can appear between digits** (same as hex/binary)
2. **Underscores cannot appear**:
   - At the start of a number: `_123` ❌
   - At the end of a number: `123_` ❌
   - Before/after decimal point: `123_.456` or `123._456` ❌
   - Before/after exponent: `1e_10` or `1_e10` ❌

3. **Underscores are stripped during parsing** (same as hex/binary)

## Implementation

Modify `scanNumber()` in `Lexer.swift` to accept and filter underscores in three locations:

```swift
// 1. Integer part (lines 460-462)
while !isAtEnd && (peek().isNumber || peek() == "_") {
    let char = advance()
    if char != "_" {
        numStr.append(char)
    }
}

// 2. Fractional part (lines 469-471)
while !isAtEnd && (peek().isNumber || peek() == "_") {
    let char = advance()
    if char != "_" {
        numStr.append(char)
    }
}

// 3. Exponent part (lines 481-483)
while !isAtEnd && (peek().isNumber || peek() == "_") {
    let char = advance()
    if char != "_" {
        numStr.append(char)
    }
}
```

This mirrors the existing implementation in `scanHexNumber()` and `scanBinaryNumber()`.

## Backward Compatibility

✅ **Fully backward compatible**
- All existing valid programs continue to work
- Underscores are opt-in, not required
- No breaking changes to syntax

## Testing Strategy

1. **Unit Tests** (add to `LexerTests.swift`):
   ```swift
   func testDecimalWithUnderscores() {
       XCTAssertEqual(lex("1_000"), .intLiteral(1000))
       XCTAssertEqual(lex("1_000_000"), .intLiteral(1000000))
   }

   func testFloatWithUnderscores() {
       XCTAssertEqual(lex("3.141_592"), .floatLiteral(3.141592))
   }

   func testExponentWithUnderscores() {
       XCTAssertEqual(lex("1.5e1_0"), .floatLiteral(1.5e10))
   }
   ```

2. **Example Program**:
   Create `Examples/NumericLiterals/` demonstrating all forms

3. **Regression Tests**:
   - All existing tests must pass
   - `./test-examples.pl` must pass

## Alternatives Considered

### 1. Different Separator Character
Use apostrophe (`'`) like C++14:
```aro
Compute the <million> from 1'000'000.
```

**Rejected**: Apostrophe is used for character literals in many languages. Underscore is the de facto standard in modern languages (Python, Rust, Swift, Java, JS).

### 2. Require Consistent Spacing
Require underscores at regular intervals (e.g., every 3 digits):
```aro
1_000_000  (* ✅ Valid *)
1_00_00_0  (* ❌ Error *)
```

**Rejected**: Too restrictive. Users should have freedom to group digits as they see fit (e.g., `1234_5678` for 8-digit numbers).

### 3. Only Support in Integers
Don't add underscore support to floating-point literals.

**Rejected**: Floating-point literals benefit equally from readability improvements, especially for scientific notation: `6.022_141_5e23`.

## Conclusion

Adding underscore support to decimal literals:
- ✅ Improves readability of large numbers
- ✅ Makes ARO consistent across all numeric bases
- ✅ Matches industry standards (Python, Rust, Java, Swift, JS)
- ✅ Zero breaking changes
- ✅ Trivial implementation (mirrors existing hex/binary code)

This is a low-risk, high-value quality-of-life improvement that aligns ARO with modern language conventions.
