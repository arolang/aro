# Build a date and time operations demo

Create a single-file ARO application that demonstrates date/time handling.

In the `Application-Start` feature set:

1. **Current time** -- Log the `<now>` framework variable (current UTC time).

2. **Date parsing** -- Parse an ISO 8601 string into a date using `Compute the <meeting: date> from "2025-06-15T14:00:00Z"`.

3. **Property extraction** -- Extract year, month, day, and hour from `<now>` using qualifiers: `Extract the <year> from the <now: year>`.

4. **Date arithmetic** -- Compute offset dates using qualifier syntax: `<next-week: +7d>`, `<yesterday: -1d>`, `<one-hour-later: +1h>` from `<now>`.

5. **Date comparisons** -- Use `when` guards to compare dates: check if yesterday is before now, if next week is after now, and whether the meeting date is in the past or future.

Log all results and return OK.
