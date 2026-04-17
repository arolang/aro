# Build a demo of all built-in compute operations

Create a single-file ARO application that showcases every built-in compute operation and the qualifier-as-name syntax.

In the `Application-Start` feature set, demonstrate:

1. **String length** -- Create two strings ("Hello, World!" and "Goodbye!"). First show the old syntax where `<length>` is both the variable name and the operation. Then show the qualifier-as-name syntax: `<greeting-length: length>` and `<farewell-length: length>` to get distinct variable names for each result.

2. **Case transformations** -- Create a mixed-case string "Hello ARO Developer" and compute both `<upperText: uppercase>` and `<lowerText: lowercase>` from it. Log the original, uppercase, and lowercase versions.

3. **Hashing** -- Create a password string "secret123" and compute `<password-hash: hash>` from it.

4. **Arithmetic** -- Compute a price calculation: price (100) times quantity (3), then 8% tax, then the total.

5. **Collection counting** -- Create a list of fruits and compute `<item-count: count>` from it.

Log all results to the console with descriptive labels.
