# Build an expressions and operators demo

Create a single-file ARO application that demonstrates literals, arithmetic, string concatenation, collections, comparisons, and boolean logic.

In the `Application-Start` feature set:

1. **Arithmetic** -- Create `<price>` (25) and `<quantity>` (4), compute subtotal, tax (8%), and total.

2. **String concatenation** -- Create `<first-name>` ("John") and `<last-name>` ("Doe"), compute `<full-name>` using the `++` operator: `<first-name> ++ " " ++ <last-name>`.

3. **Collection literals** -- Create a list `<numbers>` with `[1, 2, 3, 4, 5]` and an object `<config>` with `{ name: "Demo App", version: 1, debug: true }`.

4. **Comparisons** -- Use `Validate` to check that `<quantity>` equals 4 and `<first-name>` equals "John".

5. **Boolean expressions** -- Use `Validate` with `true and true` and `true or false`.

Log the computed values to the console and return OK.
