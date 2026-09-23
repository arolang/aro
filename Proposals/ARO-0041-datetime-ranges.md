# ARO-0041: Date/Time Range Operations

* Proposal: ARO-0041
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0010

## Abstract

This proposal defines date/time range operations including range creation, date arithmetic, span calculations, and recurrence patterns. These features extend the basic date/time support in ARO-0010.

---

## 1. Date Ranges

### 1.1 Creating Ranges

Create a range between two dates:

```aro
Create the <range> from <start-date> to <end-date>.
```

### 1.2 Range Span Properties

Extract duration information from ranges:

```aro
Create the <start> with "2024-01-01".
Create the <end> with "2024-01-15".
Create the <range> from <start> to <end>.

Extract the <total-days: days> from the <range>.
(* total-days = 14 *)

Extract the <total-hours: hours> from the <range>.
(* total-hours = 336 *)
```

### 1.3 Available Span Properties

| Property | Description |
|----------|-------------|
| `days` | Total days in range |
| `hours` | Total hours in range |
| `minutes` | Total minutes in range |
| `seconds` | Total seconds in range |

### 1.4 Range Membership

`in` tests whether an instant falls inside a range, **inclusive of both
endpoints**:

```aro
when <order-date> in <sale-period> {
    Compute the <discount> from <price> * 0.2.
}
```

`in` dispatches on its right operand — a date-range tests interval membership,
a list tests element membership, a string tests substring containment, a map
tests key membership — and is the inverse of `contains`, which dispatches on the
left. ARO-0002 §2.2 has the full operator table and used to cite "ARO-0041 §7"
for this, which is Timezone Support; the semantics were documented nowhere here
(GitLab #832).

---

## 2. Date Arithmetic

### 2.1 Adding Duration

```aro
Compute the <future-date> from <date> + <duration>.
```

### 2.2 Subtracting Duration

```aro
Compute the <past-date> from <date> - <duration>.
```

### 2.3 Duration Units

| Unit | Suffix | Example |
|------|--------|---------|
| Days | `d` | `+7d`, `-30d` |
| Hours | `h` | `+24h`, `-12h` |
| Minutes | `m` | `+30m`, `-15m` |
| Seconds | `s` | `+60s`, `-30s` |
| Weeks | `w` | `+2w`, `-1w` |
| Months | `M` | `+1M`, `-6M` |
| Years | `y` | `+1y`, `-5y` |

### 2.4 Examples

```aro
(* Tomorrow *)
Compute the <tomorrow> from <now> + 1d.

(* Last week *)
Compute the <last-week> from <now> - 7d.

(* Two hours from now *)
Compute the <later> from <now> + 2h.

(* Next month *)
Compute the <next-month> from <now> + 1M.
```

---

## 3. Distance Calculations

### 3.1 Computing Distance

Calculate the duration between two dates:

```aro
Compute the <duration: distance> from <start> to <end>.
```

### 3.2 Example

```aro
Create the <order-date> with "2024-01-10".
Create the <delivery-date> with "2024-01-15".

Compute the <shipping-days: distance> from <order-date> to <delivery-date>.
(* shipping-days = 5 (days) *)
```

---

## 4. Recurrence Patterns

### 4.1 Creating Recurrence

Define recurring schedules:

```aro
Create the <schedule> with "every <pattern>".
```

### 4.2 Supported Patterns

| Pattern | Description |
|---------|-------------|
| `every day` | Daily |
| `every monday` | Weekly on Monday |
| `every weekend` | Saturday and Sunday |
| `every weekday` | Monday through Friday |
| `every month` | Monthly |
| `every last friday` | Last Friday of each month |
| `every first monday` | First Monday of each month |

### 4.3 Examples

```aro
(* Daily backup schedule *)
Create the <backup-schedule> with "every day at 03:00".

(* Weekly meeting *)
Create the <meeting-schedule> with "every monday at 09:00".

(* Monthly report *)
Create the <report-schedule> with "every last friday".
```

---

## 5. Relative Date References

### 5.1 Magic Variables

| Variable | Description | Status |
|----------|-------------|--------|
| `<now>` | Current date/time | **resolves** |
| `<today>` | Today at midnight | not implemented |
| `<yesterday>` | Yesterday at midnight | not implemented |
| `<tomorrow>` | Tomorrow at midnight | not implemented |

**Only `<now>` resolves.** The other three fail with `Undefined variable:
today` (GitLab #833). Until they land, derive them from `<now>` with a date
offset qualifier:

### 5.2 Examples

```aro
(* Midnight today, and midnight yesterday *)
Compute the <today: date> from <now>.
Compute the <yesterday: -1d|date> from <now>.

(* Get items from today *)
Retrieve the <orders> from the <order-repository> where created >= <today>.
```

---

## 6. Date Formatting

### 6.1 Compute Format

```aro
Compute the <formatted: format> from <date> with "pattern".
```

### 6.2 Format Patterns

| Pattern | Output |
|---------|--------|
| `yyyy-MM-dd` | 2024-01-15 |
| `MM/dd/yyyy` | 01/15/2024 |
| `HH:mm:ss` | 14:30:00 |
| `yyyy-MM-dd HH:mm` | 2024-01-15 14:30 |
| `EEEE, MMMM d` | Monday, January 15 |

### 6.3 Example

```aro
Compute the <display-date: format> from <now> with "MMMM d, yyyy".
(* display-date = "January 15, 2024" *)
```

---

## 7. Timezone Support

An instant is absolute. A timezone is a way of *writing one down*. Everything
in this section follows from that, and the implementation used to contradict
it: `ARODate` carried a zone, nothing could set it, and `<now: timezone>`
answered `GMT` whatever was asked for (GitLab #865).

### 7.1 Timezone Qualifiers

```aro
Extract the <local-time: timezone> from <now> with "America/New_York".
Extract the <utc-time: UTC> from <now>.
```

Two spellings of one operation. The `with` clause form is the general one; the
zone as the qualifier reads better when it is a constant, and is accepted for
any name the qualifier form accepts.

A zone may be written as:

| Form | Example |
|------|---------|
| IANA identifier | `"Europe/Berlin"`, `"America/Los_Angeles"` |
| `UTC` / `GMT` / `Z` | `"UTC"` |
| `local` / `system` | the machine's own zone |
| Abbreviation | `"CET"`, `"PST"` |
| Fixed UTC offset | `"+02:00"`, `"-0800"`, `"UTC+2"` |

A name that is none of these **fails the statement**. It does not fall back to
UTC: quietly rendering the wrong time is how the original defect went unnoticed
for as long as it did.

Conversion is an `Extract`, not a `Compute` qualifier, even though every other
date operation (`date`, `format`, `distance`) is a Compute qualifier. It reads
one rendering of an instant out of another, which is what `Extract` is for.
`Compute the <t: timezone> …` is rejected at check time with a hint naming the
`Extract` spelling, because it is the first thing people try.

### 7.2 What conversion does and does not change

```aro
Create the <utc-event> with "2024-01-15T10:00:00Z".
Compute the <event: date> from <utc-event>.
Extract the <pacific-time: timezone> from <event> with "America/Los_Angeles".
(* pacific-time = 2024-01-15T02:00:00-08:00 *)
```

| Changes | Stays the same |
|---------|----------------|
| `iso`, `hour`, `day`, `dayOfWeek`, `weekOfYear`, `offset`, `dst` | `timestamp` — it is the instant |

Converting to a zone and back is the identity. There is no arithmetic in a
conversion, so there is nothing to round or lose.

Two properties exist for reasoning about the zone itself:

```aro
Extract the <berlin: timezone> from <now> with "Europe/Berlin".
Log <berlin: offset> to the <console>.   (* seconds from UTC, at this instant *)
Log <berlin: dst> to the <console>.      (* is DST in effect, at this instant *)
```

Both are read **at the instant**, not stored. That is the whole reason a fixed
offset is the wrong way to do this: `Europe/Berlin` is `+01:00` in January and
`+02:00` in July, and a program that hardcodes either is wrong for half the
year. It is also why a DST transition is worth an explicit test — a naive
offset implementation passes every other case.

### 7.3 Comparison across zones

**A comparison between two instants means the same thing whatever zone each is
written in.** Instants are ordered by when they happened; the rendering is not
part of the value being compared.

```aro
(* The same moment, written two ways. Neither is before the other. *)
Extract the <berlin: timezone> from <event> with "Europe/Berlin".
Extract the <tokyo: timezone> from <event> with "Asia/Tokyo".
Compare the <same> from <berlin> against <tokyo>.
(* <same: matches> is true *)
```

This is not a design choice so much as the only coherent one: if rendering
affected ordering, sorting a list of timestamps would depend on where each was
formatted. What a zone *does* affect is which local day an instant falls in —
so "orders placed on Tuesday" is a question about a zone, and the conversion is
how you ask it in the right one.

---

## 8. Use Cases

### 8.1 Booking System

```aro
(* Check if booking is within valid range *)
Create the <range> from <check-in> to <check-out>.
Extract the <nights: days> from the <range>.
Return an <OK: status> with <range> when <nights> >= 1.
```

### 8.2 Expiration Check

```aro
(* Check if subscription expired *)
Compute the <days-until: distance> from <now> to <expiry-date>.
Log "Subscription expired" to the <console> when <days-until> <= 0.
```

### 8.3 Scheduling

```aro
(* Schedule task for next business day *)
Compute the <next-day> from <now> + 1d.
(* Skip to Monday if weekend *)
```

---

## 9. Implementation

### 9.1 ARODate

```swift
public struct ARODate: Sendable {
    public let date: Date
    public let timezone: TimeZone

    public func adding(_ duration: Duration) -> ARODate
    public func distance(to other: ARODate) -> DateComponents
    public func format(with pattern: String) -> String
}
```

### 9.2 ARODateRange

```swift
public struct ARODateRange: Sendable {
    public let start: ARODate
    public let end: ARODate

    public var days: Int
    public var hours: Int
    public var minutes: Int
}
```

### 9.3 ARORecurrence

```swift
public struct ARORecurrence: Sendable {
    public let pattern: RecurrencePattern

    public func nextOccurrence(after date: ARODate) -> ARODate?
}
```

---

## Summary

| Feature | Syntax |
|---------|--------|
| **Range** | `Create the <r> from <start> to <end>.` |
| **Span** | `Extract the <days: days> from <range>.` |
| **Arithmetic** | `Compute the <r> from <date> + 7d.` |
| **Distance** | `Compute the <d: distance> from <a> to <b>.` |
| **Recurrence** | `Create the <s> with "every monday".` |
| **Format** | `Compute the <f: format> from <date> with "pattern".` |

---

## References

- `Sources/ARORuntime/DateTime/ARODate.swift` - Date type
- `Sources/ARORuntime/DateTime/ARODateRange.swift` - Range type
- `Sources/ARORuntime/DateTime/ARORecurrence.swift` - Recurrence
- `Examples/DateRangeDemo/` - Date range examples
- ARO-0010: Advanced Features - Basic date/time support
