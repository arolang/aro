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
<Create> the <range> from <start-date> to <end-date>.
```

### 1.2 Range Span Properties

Extract duration information from ranges:

```aro
<Create> the <start> with "2024-01-01".
<Create> the <end> with "2024-01-15".
<Create> the <range> from <start> to <end>.

<Extract> the <total-days: days> from the <range>.
(* total-days = 14 *)

<Extract> the <total-hours: hours> from the <range>.
(* total-hours = 336 *)
```

### 1.3 Available Span Properties

| Property | Description |
|----------|-------------|
| `days` | Total days in range |
| `hours` | Total hours in range |
| `minutes` | Total minutes in range |
| `seconds` | Total seconds in range |

---

## 2. Date Arithmetic

### 2.1 Adding Duration

```aro
<Compute> the <future-date> from <date> + <duration>.
```

### 2.2 Subtracting Duration

```aro
<Compute> the <past-date> from <date> - <duration>.
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
<Compute> the <tomorrow> from <now> + 1d.

(* Last week *)
<Compute> the <last-week> from <now> - 7d.

(* Two hours from now *)
<Compute> the <later> from <now> + 2h.

(* Next month *)
<Compute> the <next-month> from <now> + 1M.
```

---

## 3. Distance Calculations

### 3.1 Computing Distance

Calculate the duration between two dates:

```aro
<Compute> the <duration: distance> from <start> to <end>.
```

### 3.2 Example

```aro
<Create> the <order-date> with "2024-01-10".
<Create> the <delivery-date> with "2024-01-15".

<Compute> the <shipping-days: distance> from <order-date> to <delivery-date>.
(* shipping-days = 5 (days) *)
```

---

## 4. Recurrence Patterns

### 4.1 Creating Recurrence

Define recurring schedules:

```aro
<Create> the <schedule> with "every <pattern>".
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
<Create> the <backup-schedule> with "every day at 03:00".

(* Weekly meeting *)
<Create> the <meeting-schedule> with "every monday at 09:00".

(* Monthly report *)
<Create> the <report-schedule> with "every last friday".
```

---

## 5. Relative Date References

### 5.1 Magic Variables

| Variable | Description |
|----------|-------------|
| `<now>` | Current date/time |
| `<today>` | Today at midnight |
| `<yesterday>` | Yesterday at midnight |
| `<tomorrow>` | Tomorrow at midnight |

### 5.2 Examples

```aro
(* Check if date is in the past *)
<Compare> the <event-date> < <now>.

(* Get items from today *)
<Retrieve> the <orders> from the <order-repository>
    where created >= <today>.
```

---

## 6. Date Formatting

### 6.1 Compute Format

```aro
<Compute> the <formatted: format> from <date> with "pattern".
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
<Compute> the <display-date: format> from <now> with "MMMM d, yyyy".
(* display-date = "January 15, 2024" *)
```

---

## 7. Timezone Support

### 7.1 Timezone Qualifiers

```aro
<Extract> the <local-time: timezone> from <now> with "America/New_York".
<Extract> the <utc-time: UTC> from <now>.
```

### 7.2 Examples

```aro
(* Convert to different timezone *)
<Create> the <utc-event> with "2024-01-15T10:00:00Z".
<Extract> the <pacific-time: timezone> from <utc-event> with "America/Los_Angeles".
(* pacific-time = 2024-01-15T02:00:00-08:00 *)
```

---

## 8. Use Cases

### 8.1 Booking System

```aro
(* Check if booking is within valid range *)
<Create> the <range> from <check-in> to <check-out>.
<Extract> the <nights: days> from the <range>.
<Compare> the <nights> >= 1.
```

### 8.2 Expiration Check

```aro
(* Check if subscription expired *)
<Compute> the <days-until: distance> from <now> to <expiry-date>.
<Compare> the <days-until> <= 0 then <expired> = true.
```

### 8.3 Scheduling

```aro
(* Schedule task for next business day *)
<Compute> the <next-day> from <now> + 1d.
(* Skip to Monday if weekend *)
```

---

## Implementation

### 8.1 ARODate

```swift
public struct ARODate: Sendable {
    public let date: Date
    public let timezone: TimeZone

    public func adding(_ duration: Duration) -> ARODate
    public func distance(to other: ARODate) -> DateComponents
    public func format(with pattern: String) -> String
}
```

### 8.2 ARODateRange

```swift
public struct ARODateRange: Sendable {
    public let start: ARODate
    public let end: ARODate

    public var days: Int
    public var hours: Int
    public var minutes: Int
}
```

### 8.3 ARORecurrence

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
| **Range** | `<Create> the <r> from <start> to <end>.` |
| **Span** | `<Extract> the <days: days> from <range>.` |
| **Arithmetic** | `<Compute> the <r> from <date> + 7d.` |
| **Distance** | `<Compute> the <d: distance> from <a> to <b>.` |
| **Recurrence** | `<Create> the <s> with "every monday".` |
| **Format** | `<Compute> the <f: format> from <date> with "pattern".` |

---

## References

- `Sources/ARORuntime/DateTime/ARODate.swift` - Date type
- `Sources/ARORuntime/DateTime/ARODateRange.swift` - Range type
- `Sources/ARORuntime/DateTime/ARORecurrence.swift` - Recurrence
- `Examples/DateRangeDemo/` - Date range examples
- ARO-0010: Advanced Features - Basic date/time support
