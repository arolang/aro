# Build a numeric separators demo

Create a single-file ARO application that demonstrates underscore separators in numeric literals for improved readability.

In the `Application-Start` feature set:

1. **Integer literals** -- `1_000`, `1_000_000`, `1_000_000_000`.
2. **Floating-point** -- `1_234.56`, `3.141_592_653`.
3. **Scientific notation** -- `6.022e2_3`, `9.461e1_2`.
4. **Hex and binary** -- `0xFF_FF_FF`, `0b1010_1010`.
5. **Arithmetic** -- Subtract `250_000` from `1_000_000` to show separators work in expressions.

Log all values with descriptive labels.
