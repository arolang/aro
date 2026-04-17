# Build an immutability patterns demo

Create a single-file ARO application that demonstrates how immutable bindings work in ARO, covering four patterns:

1. **New-name pattern** -- Create `<price>` with 100. Apply a 20% discount to get `<discounted-price>` (price * 0.8), then add 10% tax to get `<final-price>` (discounted-price * 1.1). Each transformation produces a new variable because rebinding is not allowed.

2. **Qualifier-as-name** -- Create two words ("hello" and "world"). Compute the length of each using the qualifier-as-name syntax: `<first-len: length>` and `<second-len: length>`. This avoids the collision that would occur if both were named `<length>`.

3. **Multi-step pipeline** -- Create `<raw-message>` with "hello, aro!". Compute `<upper-message: uppercase>`, then `<message-length: length>` from the uppercase version, then `<double-length>` by multiplying the length by 2. Every intermediate value remains accessible.

4. **Loop body bindings** -- Create a list of prices [10, 25, 50]. In a for-each loop, compute `<taxed-price>` (item-price * 1.2) for each. The loop variable and computed values are isolated to each iteration.

Log all results with descriptive labels.
