# StreamingPipeline Example

Demonstrates ARO's streaming execution engine (ARO-0051) with multi-stage filtering.

## What This Example Shows

1. **Multi-stage filtering** - Chain multiple Filter operations
2. **Streaming execution** - Data flows through pipeline incrementally
3. **Constant memory** - Non-matching rows are discarded immediately
4. **Multiple aggregations** - sum, count, avg, max on filtered stream

## The Pipeline

```
10 transactions
    │
    ▼
[Stage 2: Filter year = "2024"] ─────────────────────────► 9 remain
    │
    ▼
[Stage 3: Filter amount > 500] ──────────────────────────► 6 remain
    │
    ▼
[Stage 4: Filter status = "completed"] ──────────────────► 5 remain  (6→5: all high-value are completed)
    │
    ▼
[Stage 5: Filter category = "electronics"] ──────────────► 4 remain
    │
    ▼
[Aggregations: sum, count, avg, max] ────────────────────► Final metrics
```

## Run the Example

```bash
aro run Examples/StreamingPipeline
```

## Expected Output

The pipeline progressively filters:
- 10 total transactions
- 9 from 2024 (filters out 2023)
- 6 high value (filters out amount <= 500)
- 5 completed (in this data, 6 high-value all happen to be completed)
- 4 electronics (filters out furniture/clothing)

Final aggregations:
- Total Amount: 5650.00
- Transaction Count: 4
- Average Amount: 1412.50
- Max Amount: 2000.00

## Memory Efficiency

In streaming mode:
- Each row flows through all 5 filter stages immediately
- Rejected rows are discarded without accumulation
- Only matching rows and aggregation counters are kept
- Works with arbitrarily large collections in constant memory

## Key Concepts

- **Lazy evaluation**: Pipeline builds up, executes on drain (Log/Reduce)
- **Stream teeing**: When same variable used multiple times
- **Aggregation fusion**: Multiple reduces can be single pass
