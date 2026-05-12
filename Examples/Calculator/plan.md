# Build an arithmetic calculator demo with tests

Create an ARO application that demonstrates basic arithmetic operations: addition, subtraction, multiplication, and division. Use two files:

- `calculator.aro` -- The main application (`Application-Start`). Create pairs of numeric variables and compute their sum, difference, product, and quotient, logging each result. Then demonstrate a multi-step calculation: compute a shopping cart total for 3 items at $50 each with 8% tax, showing the subtotal, tax, and total.

- `tests.aro` -- Unit tests using Given/When/Then syntax. Write test feature sets for each arithmetic operation: addition (15 + 7 = 22), subtraction (25 - 10 = 15), multiplication (6 * 8 = 48), division (100 / 4 = 25), and the complex tax calculation (50 * 3 * 1.08 = 162). Each test should use `Given` to set up inputs, `Compute` for the operation, and `Then` to assert the expected result.
