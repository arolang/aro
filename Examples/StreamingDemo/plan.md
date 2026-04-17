# Build a streaming data pipeline demo with JSONL

Create a single-file ARO application that demonstrates streaming execution with JSONL files, multi-stage filtering, and aggregation fusion.

In the `Application-Start` feature set:

1. Create a list of event log objects with timestamp, level, service, message, and time fields.
2. Write to JSONL format: `Write the <events> to "./events.jsonl"`.
3. Read back: `Read the <log-data> from "./events.jsonl"`.
4. Filter errors: `Filter the <errors> from <log-data> where <level> = "ERROR"`.
5. Multi-stage filter: filter by service ("api"), then by level ("ERROR") for API errors.
6. Reduce with `count()`, `sum(<time>)`, `avg(<time>)`, `min(<time>)`, `max(<time>)` on filtered data. Multiple reduces on the same source use aggregation fusion (single pass).
7. Filter slow requests where time > 1000.

Log results at each stage and explain the streaming benefits.
