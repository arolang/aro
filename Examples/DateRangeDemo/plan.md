# Build a date range and recurrence patterns demo

Create a single-file ARO application that demonstrates date ranges and recurrence patterns.

In the `Application-Start` feature set:

1. **Date ranges** -- Parse two dates and create a range: `Create the <vacation: date-range> from <start-date> to <end-date>`. Extract the span in days and hours using `Extract the <vacation-days: days> from <vacation>`. Create a "last 7 days" range using `<now>` and a computed date offset. Check if a date falls within a range using a `when` guard.

2. **Recurrence patterns** -- Create recurrence objects for various schedules: `Create the <daily-backup: recurrence> with "every day"`, `"every week"`, `"every monday"`, `"every 2 weeks"`, `"every last friday"`. For each, extract the next occurrence using `Extract the <next-daily: next> from <daily-backup>`.

3. **Combined usage** -- Create a Q1 2025 date range and extract its total days.

Log all results with descriptive labels and return OK.
