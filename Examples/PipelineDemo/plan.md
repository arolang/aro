# Build a pipeline operator demo

Create a single-file ARO application that demonstrates the `|>` pipeline operator for chaining transformations in a left-to-right data flow.

In the `Application-Start` feature set:

1. Chain three operations: `Extract the <text> from "hello" |> Compute the <upper: uppercase> from the <text> |> Compute the <len: length> from the <upper>.` Log text, upper, and len.

2. Chain extraction from a JSON object: `Extract the <data> from {"name": "Alice", "age": 30} |> Extract the <name> from the <data: name> |> Compute the <name-len: length> from the <name>.` Log data, name, and name-len.
