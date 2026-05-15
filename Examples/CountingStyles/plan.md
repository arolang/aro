# Build a collection counting styles comparison

Create a single-file ARO application that demonstrates two ways to count collections: `Compute` with length qualifier (OWN role) and `Reduce` with `count()` aggregation.

In the `Application-Start` feature set:

1. Create a list of fruits. Count it with `Compute the <fruit-count: length> from the <fruits>` and with `Reduce the <total: Integer> from the <fruits> with count()`.

2. Show Reduce's pipeline power: create orders, filter where status is "complete", then reduce with `count()` to count only complete orders.

3. Show Compute works on strings too: count characters in "Hello!" using the length qualifier.

Log all results with descriptive section headers.
