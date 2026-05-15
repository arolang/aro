# Build a multi-stage streaming filter pipeline

Create a single-file ARO application that demonstrates a five-stage streaming filter pipeline with constant memory usage.

In the `Application-Start` feature set:

1. Create a list of 10 transaction objects with id, year, amount, status, category, and customer fields.
2. Apply five progressive filters, each narrowing the result set:
   - Stage 2: `Filter ... where <year> = "2024"` (9 remain)
   - Stage 3: `Filter ... where <amount> > 500` (6 remain)
   - Stage 4: `Filter ... where <status> = "completed"` (5 remain)
   - Stage 5: `Filter ... where <category> = "electronics"` (4 remain)
3. Run aggregations on the final filtered set: `sum(<amount>)`, `count()`, `avg(<amount>)`, `max(<amount>)`.

Log the dataset at each stage and the aggregation results. In streaming mode, each row flows through all filter stages with O(1) memory.
