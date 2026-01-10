# ARO-0041: Date and Time Handling

* Proposal: ARO-0041
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0004, ARO-0035

## Abstract

This proposal introduces comprehensive date/time handling to ARO through:
1. A magic `<now>` variable representing the current point in time
2. Timezone support with UTC as default
3. Relative date offsets via qualifiers (`<now: +1h>`, `<now: -3d>`)
4. Date arithmetic operations
5. Date range objects with span calculations
6. Date comparisons in `when` clauses
7. Distance calculations between dates
8. Date formatting for display
9. Recurrence patterns for scheduling

---

## Motivation

Date and time operations are fundamental to business logic:

- **Scheduling**: "Send reminder 1 hour before appointment"
- **Expiration**: "Token expires in 7 days"
- **Reporting**: "Calculate days between order and delivery"
- **Validation**: "Check if promotion is currently active"
- **Auditing**: "Log timestamp of each action"
- **Recurring Tasks**: "Run cleanup every week"

Currently, ARO has no native date/time support. File metadata returns ISO 8601 strings (ARO-0036), but there's no way to create, manipulate, or compare dates.

---

## Proposed Design

### 1. The Magic `<now>` Variable

`<now>` is a built-in variable that always resolves to the current timestamp:

```aro
<Log> <now> to the <console>.
(* Output: 2025-01-15T10:30:00Z *)
```

**Semantics:**
- Evaluates to current UTC time when accessed
- Returns an ISO 8601 formatted string
- Available in all feature sets without explicit declaration

---

### 2. Timezone Handling

By default, `<now>` returns UTC. Explicit timezone qualifiers are supported:

```aro
(* UTC (default) *)
<now>              (* 2025-01-15T10:30:00Z *)
<now: utc>         (* 2025-01-15T10:30:00Z - explicit UTC *)

(* Local system time *)
<now: local>       (* 2025-01-15T11:30:00+01:00 *)

(* Named timezone (IANA) *)
<now: Europe/Berlin>     (* 2025-01-15T11:30:00+01:00 *)
<now: America/New_York>  (* 2025-01-15T05:30:00-05:00 *)
<now: Asia/Tokyo>        (* 2025-01-15T19:30:00+09:00 *)
```

**Grammar:**
```ebnf
timezone_qualifier = "utc" | "local" | iana_timezone ;
iana_timezone = region , "/" , city ;
region = "Africa" | "America" | "Antarctica" | "Asia" | "Atlantic"
       | "Australia" | "Europe" | "Indian" | "Pacific" ;
```

**Combining with Offsets:**
```aro
<now: Europe/Berlin, +1h>   (* Berlin time + 1 hour *)
<now: local, -30m>          (* Local time - 30 minutes *)
```

---

### 3. Relative Date Offsets

Qualifiers on `<now>` (or any date variable) create relative dates:

```aro
<now: +1h>    (* 1 hour from now *)
<now: -3d>    (* 3 days ago *)
<now: +2w>    (* 2 weeks from now *)
<now: -6M>    (* 6 months ago *)
<now: +1y>    (* 1 year from now *)
```

**Supported Units:**

| Short | Long | Description |
|-------|------|-------------|
| `s` | `seconds` | Seconds |
| `m` | `minutes` / `min` | Minutes |
| `h` | `hours` | Hours |
| `d` | `days` | Days |
| `w` | `weeks` | Weeks |
| `M` | `months` | Months |
| `y` | `years` | Years |

**Grammar:**
```ebnf
relative_offset = ("+" | "-") , number , time_unit ;
time_unit = "s" | "seconds" | "m" | "min" | "minutes"
          | "h" | "hours" | "d" | "days" | "w" | "weeks"
          | "M" | "months" | "y" | "years" ;
```

**Relative to Any Date:**
```aro
<Extract> the <start-date> from the <project: start>.
<Compute> the <deadline: +14d> from <start-date>.  (* 14 days after start *)
```

---

### 4. Date Parsing

Parse ISO 8601 strings into date objects using the `date` computation:

```aro
<Compute> the <meeting: date> from "2025-06-15T14:00:00Z".
<Compute> the <birthday: date> from "1990-03-21".
```

**Supported ISO 8601 Formats:**
- Full: `2025-01-15T10:30:00Z`
- With timezone: `2025-01-15T10:30:00+02:00`
- Date only: `2025-01-15` (assumes midnight UTC)
- Date and time: `2025-01-15T10:30:00` (assumes UTC)

---

### 5. Date Ranges

Create date ranges using the `Create` action with `from` and `to`:

```aro
<Create> the <vacation: date-range> from <start-date> to <end-date>.
<Create> the <this-month: date-range> from <month-start> to <now>.
```

**Span Extraction:**

Access the span of a date range using qualifiers:

```aro
<vacation: days>      (* Number of days in the range *)
<vacation: hours>     (* Number of hours *)
<vacation: minutes>   (* Number of minutes *)
<vacation: seconds>   (* Number of seconds *)
<vacation: weeks>     (* Number of complete weeks *)
```

**Range Properties:**

```aro
<vacation: start>     (* Start date of the range *)
<vacation: end>       (* End date of the range *)
```

---

### 6. Date Arithmetic

ARO supports arithmetic operations on dates:

**Adding Offsets to Dates:**
```aro
<Compute> the <due-date> from <start-date> + 14d.
<Compute> the <reminder> from <appointment> - 1h.
```

**Subtracting Dates (Duration):**
```aro
<Compute> the <duration> from <end-date> - <start-date>.
<duration: days>      (* Number of days between dates *)
<duration: hours>     (* Number of hours between dates *)
```

**Chained Operations:**
```aro
<Compute> the <extended-deadline> from <deadline> + 1w + 2d.
```

**Grammar Extension:**
```ebnf
date_expression = date_term , { ("+" | "-") , (date_term | duration_literal) } ;
date_term = variable_ref | "now" ;
duration_literal = number , time_unit ;
```

---

### 7. Date Comparisons in `when` Clauses

New comparison operators for dates:

```aro
(* Temporal comparisons *)
when <date1> before <date2>     (* date1 < date2 *)
when <date1> after <date2>      (* date1 > date2 *)
when <date1> == <date2>         (* Same instant *)

(* Range membership *)
when <date> in <range>          (* Date falls within range *)
when <date> not in <range>      (* Date outside range *)

(* Standard operators also work *)
when <date1> < <date2>
when <date1> >= <date2>
```

**Grammar Extension (ARO-0004):**
```ebnf
comparison_op += "before" | "after" ;
existence_check += expression , ["not"] , "in" , expression ;
```

---

### 8. Distance Calculations

Calculate the distance between two dates:

```aro
<Compute> the <time-until: distance> from <now> to <deadline>.
<time-until: days>     (* Days until deadline *)
<time-until: hours>    (* Hours until deadline *)
```

**Negative Distances:**
- If the first date is after the second, the result is negative
- `<Compute> the <elapsed: distance> from <start-date> to <now>.`
- If start-date was 5 days ago: `<elapsed: days>` = 5

---

### 9. Date Formatting

Format dates for display using format strings:

```aro
<Compute> the <formatted: format> from <date> with "MMM dd, yyyy".
(* Output: "Jan 15, 2025" *)

<Compute> the <time-display: format> from <now> with "HH:mm:ss".
(* Output: "10:30:00" *)

<Compute> the <full-datetime: format> from <date> with "yyyy-MM-dd'T'HH:mm:ss".
(* Output: "2025-01-15T10:30:00" *)
```

**Format Specifiers:**

| Specifier | Description | Example |
|-----------|-------------|---------|
| `yyyy` | 4-digit year | 2025 |
| `yy` | 2-digit year | 25 |
| `MM` | Month (01-12) | 01 |
| `MMM` | Month abbreviation | Jan |
| `MMMM` | Full month name | January |
| `dd` | Day of month (01-31) | 15 |
| `d` | Day of month (1-31) | 15 |
| `HH` | Hour 24h (00-23) | 10 |
| `hh` | Hour 12h (01-12) | 10 |
| `mm` | Minutes (00-59) | 30 |
| `ss` | Seconds (00-59) | 00 |
| `a` | AM/PM | AM |
| `EEEE` | Full weekday | Wednesday |
| `EEE` | Weekday abbreviation | Wed |
| `Z` | Timezone offset | +0000 |
| `z` | Timezone name | UTC |

**Locale-Aware Formatting:**
```aro
<Compute> the <german-date: format> from <date> with "dd.MM.yyyy".
(* Output: "15.01.2025" *)

<Compute> the <us-date: format> from <date> with "MM/dd/yyyy".
(* Output: "01/15/2025" *)
```

---

### 10. Recurrence Patterns

ARO supports recurrence patterns for scheduling and iteration:

**Basic Recurrence:**
```aro
<Create> the <schedule: recurrence> with "every week".
<Create> the <backup-schedule: recurrence> with "every day".
<Create> the <meeting: recurrence> with "every month".
```

**Interval Recurrence:**
```aro
<Create> the <schedule: recurrence> with "every 2nd day".
<Create> the <biweekly: recurrence> with "every 2 weeks".
<Create> the <quarterly: recurrence> with "every 3 months".
```

**Day-of-Week Recurrence:**
```aro
<Create> the <standup: recurrence> with "every monday".
<Create> the <team-meeting: recurrence> with "every second monday".
<Create> the <review: recurrence> with "every last friday".
```

**Grammar:**
```ebnf
recurrence_pattern = "every" , recurrence_interval ;
recurrence_interval = time_unit
                    | ordinal , time_unit
                    | number , time_unit
                    | weekday
                    | ordinal , weekday ;
ordinal = "2nd" | "3rd" | number "th" | "second" | "third" | "last" | ... ;
weekday = "monday" | "tuesday" | "wednesday" | "thursday"
        | "friday" | "saturday" | "sunday" ;
```

**Recurrence Properties:**
```aro
<schedule: next>        (* Next occurrence from now *)
<schedule: previous>    (* Previous occurrence *)
<schedule: occurrences> (* List of upcoming dates, default 10 *)
```

**Getting Occurrences in a Range:**
```aro
<Compute> the <meetings: occurrences> from <schedule> in <date-range>.
```

**Recurrence with Start Date:**
```aro
<Create> the <schedule: recurrence> with "every week" from <start-date>.
```

---

## Date Object Structure

When a date is resolved, it contains these properties accessible via qualifiers:

```typescript
DateObject {
    iso: string,           // "2025-01-15T10:30:00Z"
    year: number,          // 2025
    month: number,         // 1 (1-12)
    day: number,           // 15 (1-31)
    hour: number,          // 10 (0-23)
    minute: number,        // 30 (0-59)
    second: number,        // 0 (0-59)
    dayOfWeek: string,     // "Wednesday"
    dayOfYear: number,     // 15 (1-366)
    weekOfYear: number,    // 3 (1-53)
    timestamp: number,     // Unix timestamp in seconds
    timezone: string       // "UTC" or IANA timezone
}
```

**Access:**
```aro
<Extract> the <year> from the <now: year>.
<Extract> the <day-name> from the <appointment: dayOfWeek>.
<Extract> the <unix-time> from the <now: timestamp>.
```

---

## Implementation

### DateService Protocol

Register a `DateService` in the execution context:

```swift
public protocol DateService: Sendable {
    func now(timezone: String?) -> Date
    func parse(_ iso8601: String) throws -> Date
    func offset(_ date: Date, by: DateOffset) -> Date
    func distance(from: Date, to: Date) -> DateDistance
    func format(_ date: Date, pattern: String) -> String
    func createRange(from: Date, to: Date) -> DateRange
    func createRecurrence(pattern: String, from: Date?) -> Recurrence
}

public struct DateOffset: Sendable {
    let value: Int
    let unit: DateUnit
}

public enum DateUnit: String, Sendable {
    case seconds, minutes, hours, days, weeks, months, years
}

public struct DateRange: Sendable {
    let start: Date
    let end: Date

    func span(_ unit: DateUnit) -> Int
    func contains(_ date: Date) -> Bool
}

public struct Recurrence: Sendable {
    let pattern: String
    let startDate: Date?

    func next(from: Date) -> Date
    func previous(from: Date) -> Date
    func occurrences(in range: DateRange, limit: Int) -> [Date]
}
```

**Benefits:**
- Clean separation of concerns
- Testable (inject mock time in tests)
- Follows existing service pattern (like ComputationService)

### Runtime Recognition of `<now>`

The runtime recognizes `now` as a special identifier:

```swift
func resolve(_ name: String, qualifiers: [String]) -> Any? {
    if name == "now" {
        return dateService.now(timezone: extractTimezone(qualifiers))
    }
    return variables[name]
}
```

---

## Complete Example

```aro
(Application-Start: Booking System) {
    <Start> the <http-server> with <contract>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(createBooking: Booking API) {
    <Extract> the <data> from the <request: body>.
    <Extract> the <booking-date-str> from the <data: date>.

    (* Parse the booking date *)
    <Compute> the <booking-date: date> from <booking-date-str>.

    (* Validate: booking must be at least 24 hours in advance *)
    <Compute> the <min-booking-time: +24h> from <now>.
    <Return> a <BadRequest: status> with "Must book at least 24 hours in advance"
        when <booking-date> before <min-booking-time>.

    (* Validate: booking cannot be more than 90 days out *)
    <Compute> the <max-booking-time: +90d> from <now>.
    <Return> a <BadRequest: status> with "Cannot book more than 90 days ahead"
        when <booking-date> after <max-booking-time>.

    (* Create the booking with expiration *)
    <Compute> the <confirmation-expires: +15m> from <now>.
    <Create> the <booking> with {
        date: <booking-date>,
        created: <now>,
        confirmBy: <confirmation-expires>,
        status: "pending"
    }.

    <Store> the <booking> into the <booking-repository>.
    <Emit> a <BookingCreated: event> with <booking>.
    <Return> a <Created: status> with <booking>.
}

(Expire Pending Bookings: Scheduled Task) {
    <Retrieve> the <pending-bookings> from the <booking-repository>
        where <status> = "pending".

    (* Check each booking's confirmation deadline *)
    for <booking> in <pending-bookings> {
        <Extract> the <confirm-by> from the <booking: confirmBy>.
        <Delete> the <booking> from the <booking-repository>
            when <now> after <confirm-by>.
        <Emit> a <BookingExpired: event> with <booking>
            when <now> after <confirm-by>.
    }

    <Return> an <OK: status> for the <cleanup>.
}

(Generate Monthly Report: Analytics) {
    (* Calculate date range for last 30 days *)
    <Compute> the <report-start: -30d> from <now>.
    <Create> the <report-period: date-range> from <report-start> to <now>.

    (* Get the span *)
    <Extract> the <days-in-report: days> from <report-period>.

    (* Retrieve bookings in range *)
    <Retrieve> the <bookings> from the <booking-repository>
        where <created> in <report-period>.

    <Compute> the <booking-count: count> from <bookings>.

    (* Format for display *)
    <Compute> the <report-date: format> from <now> with "MMMM dd, yyyy".

    <Return> an <OK: status> with {
        period: <report-period>,
        days: <days-in-report>,
        totalBookings: <booking-count>,
        generatedAt: <report-date>
    }.
}

(Weekly Cleanup: Scheduled Task) {
    (* Create weekly recurrence *)
    <Create> the <cleanup-schedule: recurrence> with "every sunday".

    (* Check if today is a cleanup day *)
    <Extract> the <today: dayOfWeek> from <now>.
    <Return> an <OK: status> with "Not cleanup day" when <today> != "Sunday".

    (* Perform cleanup *)
    <Retrieve> the <old-bookings> from the <booking-repository>
        where <created> before <now: -90d>.

    for <booking> in <old-bookings> {
        <Delete> the <booking> from the <booking-repository>.
    }

    <Return> an <OK: status> for the <cleanup>.
}
```

---

## Recurrence Examples

```aro
(Schedule Standup: Team Management) {
    (* Daily standup every weekday at 9 AM *)
    <Create> the <standup: recurrence> with "every monday".
    <Create> the <standup-tue: recurrence> with "every tuesday".
    <Create> the <standup-wed: recurrence> with "every wednesday".
    <Create> the <standup-thu: recurrence> with "every thursday".
    <Create> the <standup-fri: recurrence> with "every friday".

    <Return> an <OK: status> with <standup: next>.
}

(Biweekly Report: Analytics) {
    <Create> the <report-schedule: recurrence> with "every 2 weeks".
    <Compute> the <next-report: next> from <report-schedule>.
    <Return> an <OK: status> with <next-report>.
}

(Monthly Billing: Payments) {
    <Create> the <billing-schedule: recurrence> with "every month".
    <Compute> the <next-billing: next> from <billing-schedule>.

    (* Get all billing dates for the year *)
    <Compute> the <year-start: date> from "2025-01-01".
    <Compute> the <year-end: date> from "2025-12-31".
    <Create> the <year-range: date-range> from <year-start> to <year-end>.

    <Compute> the <billing-dates: occurrences> from <billing-schedule> in <year-range>.

    <Return> an <OK: status> with <billing-dates>.
}
```

---

## Source Compatibility

This change is additive. The `<now>` identifier is reserved and cannot be used as a variable name. All other syntax is new and does not conflict with existing code.

---

## Alternatives Considered

### 1. System Object Pattern

Expose dates through a `<system>` object:

```aro
<Extract> the <current-time: now> from the <system: date>.
<Extract> the <timezone> from the <system: timezone>.
```

**Rejected**: More verbose than `<now>`, requires defining what "system" contains.

### 2. Explicit Date Action

Require an action to get current time:

```aro
<Get> the <current-time: now> from the <system>.
```

**Rejected**: Adds unnecessary verbosity for a fundamental operation.

### 3. Business Day Support

Support business day calculations like `<now: +5bd>`:

**Rejected**: Business day definitions vary by region and organization. Better handled via custom recurrence patterns or plugins.

---

## References

- ARO-0004: Conditional Branching (when clauses)
- ARO-0035: Qualifier-as-Name Result Syntax
- ARO-0036: Native File Operations (ISO 8601 timestamps)
- ISO 8601: Date and time format standard
- IANA Time Zone Database: https://www.iana.org/time-zones
