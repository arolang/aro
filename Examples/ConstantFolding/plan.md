# Build a constant folding optimization test

Create a single-file ARO application that demonstrates compile-time constant folding for expressions.

In the `Application-Start` feature set, compute and log results for:

1. Arithmetic constant expressions: `5 * 10 + 2`, `100 / 4 - 3`, `17 % 5`.
2. Comparison expressions: `10 > 5`, `3 + 2 == 5`.
3. Logical expressions: `true and false`, `true or false`.
4. Nested expressions: `(5 + 3) * (10 - 2)`.

All of these should be computed at compile time. Log each expression and its result.
