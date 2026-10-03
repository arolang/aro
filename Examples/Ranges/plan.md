# Build a ranges demo

Create a single-file ARO application demonstrating range values (ARO-0089):
`1..10` includes both ends, `1..<10` excludes the upper one.

Define a user-defined action `Histogram` that takes `{ hours: … }`, computes
the length of the collection it is given, and returns `{ buckets: <length> }`.

In the `Application-Start` feature set, with a `=== … ===` heading logged
before each part:

1. **Both ends** — `for each <n> in 1..5`, logging each value.

2. **Upper end excluded** — `for each <n> in 1..<5`, logging each value.

3. **Computed endpoints** — bind `<lo>` to 2 and `<hi>` to 4, then iterate
   `<lo>..<hi>` (inclusive, three values) and `<lo>..< <hi>` (exclusive, two
   values). The space in the second one is required: `..<<` is rejected,
   because `<lo>..<hi>` and `<lo>..<` + `<hi>` are otherwise the same
   characters.

4. **Precedence** — a range binds looser than arithmetic, so
   `Compute the <span: length> from 1..<hi> + 1.` measures `1..(<hi> + 1)`
   and logs 5.

5. **Measuring** — log the length of `1..10` (10) and of `1..<10` (9).

6. **A descending range is empty** — log the length of `10..1` (0). Reversing
   is `Reverse`, not a backwards range.

7. **Numeric separators** — log the length of `1_001..2_000` (1000).

8. **As a value** — `Create the <decade> with 1..10.` and log it (a list of
   ten), `Compute the <total: sum> from 1..10.` (55), `Filter the <big> from
   1..10 where <item> > 7.` (`[8, 9, 10]`), and
   `Application.Histogram the <day> with { hours: 0..<24 }.`, logging
   `<day: buckets>` (24).

9. **Filter and index on a range loop** — `for each <n> at <i> in 1..10 where
   <n> % 3 == 0`, logging 3, 6 and 9.

10. **A large range costs two integers** — `for each <n> in 1..300_000 where
    <n> > 299_998`, logging 299999 and 300000. The collection slot is the one
    place a range is never materialised, so this loop's memory does not grow
    with the span.

Return OK at the end.
