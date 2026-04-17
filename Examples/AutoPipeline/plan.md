# Build an automatic pipeline detection demo

Create a single-file ARO application that demonstrates how ARO automatically detects and optimizes data pipelines without needing an explicit pipe operator.

In the `Application-Start` feature set:

1. Extract a list of user objects from an inline list literal. Filter adults where age > 27. Log the filtered results.

2. Extract text "hello", compute uppercase, then compute length -- showing chained transformations that ARO automatically treats as a pipeline.

Log results throughout and return OK.
