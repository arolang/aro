# Chapter 35: Date and Time

*"Time is the fire in which we burn."*

---

## 35.1 The Nature of Time in ARO

Time is a fundamental dimension of business logic. Orders have timestamps. Contracts have deadlines. Meetings have schedules. Reports have periods. Almost every business domain involves temporal reasoning in some form.

ARO approaches time with the same philosophy it applies to everything else: make the common case simple, keep the complex case possible. Most applications need to know the current time, compare two dates, or calculate how much time remains until a deadline. These operations should be trivial. More sophisticated needs—timezone conversions, recurrence patterns, calendar arithmetic—should be accessible when required.

The foundation of ARO's temporal model is UTC (Coordinated Universal Time). All dates are UTC by default. This eliminates a vast category of bugs that plague systems where timezone handling is implicit or inconsistent. When you need local time or a specific timezone, you ask for it explicitly. The default is always unambiguous.

---

## 35.2 The Magic `<now>` Variable

ARO provides a special variable that exists without declaration: `<now>`. This magic variable always resolves to the current UTC timestamp:

```aro
<Log> <now> to the <console>.
```

The output follows ISO 8601 format: `2025-12-29T15:20:49Z`. The trailing `Z` indicates UTC. This format is unambiguous, sortable as text, and universally understood by APIs and databases.

Unlike regular variables, `<now>` needs no prior binding. It exists in every feature set, always available, always current. Each evaluation captures a new instant—if you reference `<now>` twice in quick succession, you might get slightly different values.

<div style="display: flex; justify-content: center; margin: 2em 0;">
<svg width="400" height="120" viewBox="0 0 400 120" xmlns="http://www.w3.org/2000/svg">
  <rect x="50" y="30" width="300" height="60" rx="10" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>
  <text x="200" y="55" text-anchor="middle" font-family="monospace" font-size="14" fill="#1e40af">&lt;now&gt;</text>
  <text x="200" y="75" text-anchor="middle" font-family="sans-serif" font-size="12" fill="#3b82f6">2025-12-29T15:20:49Z</text>
  <text x="200" y="110" text-anchor="middle" font-family="sans-serif" font-size="10" fill="#64748b">Always available. Always UTC. Always current.</text>
</svg>
</div>

---

## 35.3 Extracting Date Components

Dates contain structured information: years, months, days, hours, minutes, seconds. ARO exposes these components through qualifiers:

```aro
<Extract> the <year> from the <now: year>.
<Extract> the <month> from the <now: month>.
<Extract> the <day> from the <now: day>.
<Extract> the <hour> from the <now: hour>.
<Extract> the <minute> from the <now: minute>.
<Extract> the <second> from the <now: second>.
```

Each extraction produces an integer. The month is 1-indexed (January = 1, December = 12). The hour uses 24-hour format (0-23). The day of week follows ISO convention: Sunday = 1, Monday = 2, through Saturday = 7.

<div style="display: flex; flex-wrap: wrap; justify-content: center; gap: 1em; margin: 2em 0;">

<div style="text-align: center;">
<svg width="90" height="70" viewBox="0 0 90 70" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="15" width="80" height="40" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>
  <text x="45" y="40" text-anchor="middle" font-family="monospace" font-size="14" fill="#1e40af">2025</text>
  <text x="45" y="65" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#64748b">year</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="90" height="70" viewBox="0 0 90 70" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="15" width="80" height="40" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>
  <text x="45" y="40" text-anchor="middle" font-family="monospace" font-size="14" fill="#166534">12</text>
  <text x="45" y="65" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#64748b">month</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="90" height="70" viewBox="0 0 90 70" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="15" width="80" height="40" rx="5" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="45" y="40" text-anchor="middle" font-family="monospace" font-size="14" fill="#92400e">29</text>
  <text x="45" y="65" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#64748b">day</text>
</svg>
</div>

<div style="text-align: center;">
<svg width="90" height="70" viewBox="0 0 90 70" xmlns="http://www.w3.org/2000/svg">
  <rect x="5" y="15" width="80" height="40" rx="5" fill="#f3e8ff" stroke="#a855f7" stroke-width="2"/>
  <text x="45" y="40" text-anchor="middle" font-family="monospace" font-size="14" fill="#7c3aed">15</text>
  <text x="45" y="65" text-anchor="middle" font-family="sans-serif" font-size="9" fill="#64748b">hour</text>
</svg>
</div>

</div>

Additional properties include `timestamp` (Unix epoch seconds), `iso` (the full ISO 8601 string), and `timezone` (the timezone identifier).

---

## 35.4 Parsing Date Strings

External systems send dates as strings. Users enter dates in forms. Configuration files specify dates in text. ARO parses these into proper date objects:

```aro
<Compute> the <deadline: date> from "2025-12-31T23:59:59Z".
```

The qualifier `: date` tells Compute to interpret the input string as an ISO 8601 date. Once parsed, the result behaves like any other date—you can extract components, calculate distances, or compare it against other dates.

Supported formats include:

- Full ISO 8601: `2025-12-31T23:59:59Z`
- With timezone offset: `2025-12-31T23:59:59+02:00`
- Date only: `2025-12-31` (time defaults to midnight UTC)
- Date with time, no zone: `2025-12-31T14:30:00` (assumes UTC)

The parser is strict. Invalid dates produce errors rather than surprising interpretations. December 32nd doesn't silently become January 1st.

---

## 35.5 Formatting Dates

Dates need to be displayed to users, and different contexts call for different formats. Europeans expect day-month-year. Americans expect month-day-year. Formal documents want full month names. Log files want compact timestamps.

```aro
<Compute> the <display: format> from <deadline> with "MMMM dd, yyyy".
```

The second parameter is a format pattern. Common patterns include:

| Pattern | Result |
|---------|--------|
| `yyyy-MM-dd` | 2025-12-31 |
| `MMMM dd, yyyy` | December 31, 2025 |
| `MMM dd, yyyy` | Dec 31, 2025 |
| `dd.MM.yyyy` | 31.12.2025 |
| `HH:mm:ss` | 23:59:59 |
| `hh:mm a` | 11:59 PM |

The pattern language follows standard conventions. Four `y`s mean four-digit year. Four `M`s mean full month name. Two `d`s mean zero-padded day. This allows precise control over output format.

---

## 35.6 Relative Offsets

Business logic often involves relative dates. "Tomorrow" is one day from now. "Next week" is seven days from now. "The booking expires in 24 hours." These relative calculations are expressed through offset qualifiers:

```aro
<Compute> the <tomorrow: +1d> from <now>.
<Compute> the <yesterday: -1d> from <now>.
<Compute> the <next-week: +7d> from <now>.
<Compute> the <expires: +24h> from <created-at>.
```

The offset consists of a sign (`+` or `-`), a number, and a unit. Available units:

| Unit | Meaning |
|------|---------|
| `s` | Seconds |
| `m` | Minutes |
| `h` | Hours |
| `d` | Days |
| `w` | Weeks |
| `M` | Months |
| `y` | Years |

Offsets can be chained by computing from an already-offset date:

```aro
<Compute> the <next-month: +1M> from <now>.
<Compute> the <next-month-plus-week: +1w> from <next-month>.
```

---

## 35.7 Date Ranges

Many business concepts span periods: fiscal quarters, subscription terms, booking windows, sale periods. ARO represents these as date ranges:

```aro
<Create> the <q4: date-range> from <oct-first> to <dec-thirty-first>.
```

Ranges expose useful properties:

```aro
<Extract> the <duration: days> from <q4>.
<Extract> the <duration: hours> from <q4>.
<Extract> the <start> from the <q4: start>.
<Extract> the <end> from the <q4: end>.
```

The range membership operator `in` enables temporal queries in when clauses:

```aro
when <order-date> in <sale-period> {
    <Compute> the <discount> from <price> * 0.2.
}
```

---

## 35.8 Date Comparisons

Dates can be compared using `before` and `after` operators in when clauses:

```aro
when <booking-date> before <deadline> {
    <Log> "Booking accepted" to the <console>.
}

when <event-date> after <now> {
    <Log> "Event is upcoming" to the <console>.
}
```

These temporal comparisons read naturally and express intent clearly. The runtime handles the underlying timestamp comparison.

---

## 35.9 Distance Between Dates

How many days until the deadline? How many hours since the last update? These questions require calculating the distance between two dates:

```aro
<Compute> the <remaining: distance> from <now> to <deadline>.
<Extract> the <days-left> from the <remaining: days>.
<Extract> the <hours-left> from the <remaining: hours>.
```

The distance operation captures the interval between two points in time. You can then extract that distance in whatever units make sense for your domain—days for project timelines, hours for SLA tracking, seconds for performance metrics.

---

## 35.10 Recurrence Patterns

Some events repeat: weekly meetings, monthly reports, annual reviews. ARO supports recurrence patterns:

```aro
<Create> the <standup: recurrence> with "every monday".
<Create> the <monthly-report: recurrence> with "every month".
<Create> the <biweekly: recurrence> with "every 2 weeks".
```

From a recurrence, you can extract the next or previous occurrence:

```aro
<Extract> the <next-meeting> from the <standup: next>.
<Extract> the <last-meeting> from the <standup: previous>.
```

Supported patterns include:

- Simple intervals: `every day`, `every week`, `every month`, `every year`
- Numbered intervals: `every 2 days`, `every 3 weeks`
- Weekday patterns: `every monday`, `every friday`
- Ordinal weekdays: `every second tuesday`, `every last friday`

---

## 35.11 Design Philosophy

ARO's date handling embodies several principles:

**UTC First**: Dates are UTC unless explicitly converted. This eliminates ambiguity and the bugs that come with implicit timezone assumptions.

**ISO 8601**: The standard format for storage and exchange. Human-readable, machine-parseable, sortable as strings.

**Qualifier Syntax**: Date operations use the same qualifier mechanism as other ARO operations. No special syntax to learn—just `<now: year>` like `<user: name>`.

**Immutability**: Date operations produce new dates rather than modifying existing ones. `<now: +1d>` doesn't change `<now>`; it creates a new date.

**Fail Fast**: Invalid dates produce errors at parse time, not surprising behavior at runtime. December 32nd is an error, not January 1st.

---

## 35.12 Summary

Time handling in ARO provides:

- **`<now>`**: Magic variable for current UTC time
- **Properties**: `year`, `month`, `day`, `hour`, `minute`, `second`, `dayOfWeek`, `timestamp`, `iso`
- **Parsing**: Convert ISO 8601 strings to dates
- **Formatting**: Convert dates to strings with custom patterns
- **Offsets**: Calculate relative dates with `+/-` notation
- **Ranges**: Represent periods with start and end dates
- **Comparisons**: `before` and `after` operators
- **Distance**: Calculate intervals between dates
- **Recurrence**: Define repeating patterns

With these tools, ARO handles the temporal dimension of business logic clearly and consistently.

---

*Next: Appendix A — Action Reference*
