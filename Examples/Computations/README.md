# Computations Example

This example demonstrates ARO's computation capabilities, including:

- **String length** - Count characters in strings
- **Case transformations** - Convert to uppercase/lowercase
- **Hashing** - Compute hash values
- **Arithmetic** - Mathematical operations
- **Collection counting** - Count items in arrays

## Key Concept: Qualifier-as-Name Syntax

When computing multiple values of the same type, use the qualifier-as-name syntax to give each result a distinct variable name:

```aro
(* Old syntax: 'length' is both variable name AND operation *)
<Compute> the <length> from the <greeting>.

(* New syntax: 'greeting-length' is the variable, 'length' is the operation *)
<Compute> the <greeting-length: length> from the <greeting>.
<Compute> the <farewell-length: length> from the <farewell>.

(* Now both lengths are available for comparison *)
<Compare> the <greeting-length> against the <farewell-length>.
```

## Built-in Operations

| Operation | Description | Example |
|-----------|-------------|---------|
| `length` | Character/element count | `<Compute> the <len: length> from <text>.` |
| `count` | Alias for length | `<Compute> the <num: count> from <items>.` |
| `uppercase` | Convert to UPPERCASE | `<Compute> the <upper: uppercase> from <text>.` |
| `lowercase` | Convert to lowercase | `<Compute> the <lower: lowercase> from <text>.` |
| `hash` | Compute hash value | `<Compute> the <hash: hash> from <password>.` |

## Running the Example

```bash
# From the ARO-Lang root directory
swift build
.build/debug/aro run ./Examples/Computations
```

## Expected Output

```
=== ARO Computations Demo ===
Greeting length (old syntax): 13
Greeting length (new syntax): 13
Farewell length: 8
Original: Hello ARO Developer
Uppercase: HELLO ARO DEVELOPER
Lowercase: hello aro developer
Password hash: 839201...
Price: 100
Quantity: 3
Subtotal: 300
Tax (8%): 24
Total: 324
Number of items: 4
=== Demo Complete ===
```

## See Also

- [Documentation: Computations](../../Documentation/LanguageGuide/Computations.md)
- [Book: Chapter 7 - Computations](../../Book/TheLanguageGuide/Chapter07-Computations.md)
- [Proposal: ARO-0035 Qualifier-as-Name](../../Proposals/ARO-0035-qualifier-as-name.md)
