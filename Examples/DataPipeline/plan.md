# Build a data pipeline with filter, reduce, and map operations

Create an ARO application that demonstrates data pipeline operations: Filter, Reduce, and Map.

The application needs two files:

- `openapi.yaml` -- A contract with no HTTP paths (just `paths: {}`) but with schema definitions for Order, OrderSummary, User, UserSummary, Product, and AnalyticsReport types.

- `main.aro` -- The `Application-Start` feature set with four tests:

  1. **Simple array reduce** -- Create a list of numbers [1,2,3,4,5]. Use `Reduce` with `count()`, `sum()`, `avg()`, `min()`, and `max()` aggregations. Log each result.

  2. **Object array with filter** -- Create a list of order objects with id, amount, and status fields. Use `Filter the <active-orders: List> from the <orders> where <status> is "active"` to get active orders. Then use `Reduce` with `sum(<amount>)`, `count()`, and `avg(<amount>)` on the filtered list.

  3. **Map operation** -- Use `Map the <mapped-orders: List> from the <active-orders>` as a pass-through transformation.

  4. **Numeric filter** -- Filter orders where `<amount> > 200` and compute the sum of those high-value orders.

Log all results with descriptive headers.
