# Build a serial vs parallel iteration comparison

Create a single-file ARO application that demonstrates both serial and parallel for-each loops.

In the `Application-Start` feature set, create a list of numbers 1 through 10. First iterate serially with `for each <number> in <numbers>`, logging each number (deterministic order). Then iterate in parallel with `parallel for each <number> in <numbers>`, logging each number (non-deterministic order due to concurrent execution).
