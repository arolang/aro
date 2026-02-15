# ARO-0010: Advanced Features

* Proposal: ARO-0010
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0002, ARO-0004

## Abstract

This proposal extends ARO with advanced features for system interaction, pattern matching, and temporal operations: system command execution, regular expressions, and date/time handling. These features enable ARO applications to interact with the host system, perform sophisticated text matching, and handle temporal logic.

## Introduction

Business applications frequently need capabilities beyond basic data processing:

```
+------------------+     +------------------+     +------------------+
|   System Exec    |     | Regular Exprs    |     | Date/Time        |
|   <Exec> ...     |     | /pattern/flags   |     | <now>, offsets   |
+--------+---------+     +--------+---------+     +--------+---------+
         |                        |                        |
         v                        v                        v
+--------+---------+     +--------+---------+     +--------+---------+
| Run shell cmds   |     | Pattern matching |     | Temporal logic   |
| Build pipelines  |     | Text validation  |     | Scheduling       |
| DevOps tooling   |     | Data extraction  |     | Expiration       |
+------------------+     +------------------+     +------------------+
```

---

## 1. System Execute Action

The `<Execute>` action executes shell commands on the host system, returning structured results.

### 1.1 Syntax

```aro
(* Preferred syntax: command in object specifier *)
<Execute> the <result> for the <command: "uptime">.

(* Command with arguments *)
<Execute> the <result> for the <command: "ls"> with "-la".

(* Command with multiple arguments *)
<Execute> the <result> for the <command: "ls"> with ["-l", "-a", "-h"].

(* Legacy syntax: full command in with clause *)
<Execute> the <result> with "ls -la".

(* Execute with options *)
<Execute> the <result> with {
    command: "npm install",
    workingDirectory: "/app",
    timeout: 60000
}.
```

### 1.2 Action Specification

| Property | Value |
|----------|-------|
| **Action** | Execute |
| **Verbs** | `exec`, `execute`, `run`, `shell` |
| **Role** | REQUEST (External to Internal) |
| **Prepositions** | `with`, `for`, `on` |

### 1.3 Result Structure

Every `<Execute>` action returns a structured result object:

```
+------------------+----------------------------------------+
| Field            | Description                            |
+------------------+----------------------------------------+
| error            | Boolean - true if command failed       |
| message          | Human-readable status message          |
| output           | Command stdout (or stderr if error)    |
| exitCode         | Process exit code (0 = success)        |
| command          | The executed command (for debugging)   |
+------------------+----------------------------------------+
```

### 1.4 Configuration Options

```
+------------------+----------------------------------------+
| Option           | Description                            |
+------------------+----------------------------------------+
| command          | Required: the shell command to execute |
| workingDirectory | Optional: working directory (default:  |
|                  | current)                               |
| environment      | Optional: additional environment vars  |
| timeout          | Optional: timeout in ms (default:      |
|                  | 30000)                                 |
| shell            | Optional: shell to use (default:       |
|                  | /bin/sh)                               |
+------------------+----------------------------------------+
```

### 1.5 Examples

#### Basic Command Execution

```aro
(System Check: DevOps) {
    <Execute> the <result> with "df -h".

    match <result: error> {
        case true {
            <Log> "Command failed" to the <console>.
            <Return> an <Error: status> with <result>.
        }
        case false {
            <Log> <result: output> to the <console>.
            <Return> an <OK: status> with <result>.
        }
    }
}
```

#### Build Pipeline

```aro
(Build Project: CI Pipeline) {
    (* Run tests *)
    <Execute> the <test-result> with {
        command: "npm test",
        workingDirectory: "/app",
        timeout: 120000
    }.

    <Return> an <Error: status> with <test-result>
        when <test-result: error> is true.

    (* Build if tests pass *)
    <Execute> the <build-result> with {
        command: "npm run build",
        workingDirectory: "/app",
        environment: { NODE_ENV: "production" }
    }.

    <Return> an <OK: status> with <build-result>.
}
```

#### With Environment Variables

```aro
(Deploy: Infrastructure) {
    <Execute> the <result> with {
        command: "make release",
        environment: {
            CC: "clang",
            CFLAGS: "-O2",
            BUILD_VERSION: "1.2.3"
        }
    }.

    <Return> an <OK: status> with <result>.
}
```

### 1.6 Error Handling

When a command fails, the result captures the error state:

```aro
(Health Check: Monitoring) {
    <Execute> the <result> with "curl -s http://localhost:8080/health".

    match <result: error> {
        case true {
            <Log> "Health check failed" to the <console>.
            <Emit> a <HealthCheckFailed: event> with <result>.
        }
        case false {
            <Log> "Service healthy" to the <console>.
        }
    }

    <Return> an <OK: status> with <result>.
}
```

### 1.7 Security Considerations

#### Command Injection Prevention

Validate and sanitize user input before using in commands:

```aro
(Lookup File: File API) {
    <Extract> the <path> from the <request: path>.

    (* Validate input before use *)
    <Validate> the <safe-path> for the <path> against "^[a-zA-Z0-9_/.-]+$".
    <Return> a <BadRequest: status> with "Invalid path characters"
        when <safe-path> is not <valid>.

    <Execute> the <result> with "ls -la ${safe-path}".
    <Return> an <OK: status> with <result>.
}
```

#### Audit Logging

All `<Execute>` commands are logged with:
- Timestamp
- Feature set name
- Command executed
- Exit code
- Execution duration

---

## 2. Regular Expressions

ARO supports regular expression literals for pattern matching in match statements, where clauses, and the Split action.

### 2.1 Regex Literal Syntax

```aro
/pattern/flags
```

Regex literals use forward slashes as delimiters with optional flags after the closing slash.

### 2.2 Flags

| Flag | Description | Example |
|------|-------------|---------|
| `i` | Case insensitive | `/hello/i` matches "HELLO" |
| `s` | Dot matches newlines (dotall) | `/a.b/s` matches "a\nb" |
| `m` | Multiline (^ and $ match line boundaries) | `/^line/m` |
| `g` | Global (reserved for future replace) | - |

### 2.3 Examples

```aro
(* Simple pattern *)
/^hello/

(* Case-insensitive match *)
/^[a-z]+$/i

(* Email pattern *)
/^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i

(* Escaped slashes *)
/path\/to\/file/

(* Complex pattern with flags *)
/^ERROR:\s+(.*)$/im
```

### 2.4 Usage in Match Statements

Regex patterns work as case patterns in match statements:

```aro
(Route Message: Message Handler) {
    <Extract> the <content> from the <message: content>.

    match <content> {
        case /^\/help/i {
            <Emit> a <HelpRequested: event> with <message>.
        }
        case /^\/status\s+(\w+)$/i {
            <Emit> a <StatusQuery: event> with <message>.
        }
        case /^ERROR:/i {
            <Log> "Error detected" to the <console>.
            <Emit> an <ErrorReceived: event> with <message>.
        }
        otherwise {
            <Emit> a <MessageReceived: event> with <message>.
        }
    }

    <Return> an <OK: status> for the <routing>.
}
```

#### Match Semantics

- Patterns are tested using regex matching
- A match succeeds if any part of the string matches the pattern
- Use `^` and `$` anchors for full-string matching
- Cases are evaluated in order; first match wins

### 2.5 Usage in Where Clauses

Regex literals work with the `matches` operator:

```aro
(* Filter by pattern *)
<Retrieve> the <users> from the <user-repository>
    where <name> matches /Frodo\s+.*$/i.

(* Validate email format *)
<Filter> the <valid-emails> from the <emails>
    where <address> matches /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i.

(* Find admin users by email *)
<Retrieve> the <admins> from the <user-repository>
    where <email> matches /^admin@|@admin\./i.
```

### 2.6 Split Action with Regex

The Split action divides strings using regex delimiters:

```aro
(* Split by comma *)
<Split> the <fields> from the <csv-line> by /,/.

(* Split by whitespace *)
<Split> the <words> from the <sentence> by /\s+/.

(* Split by multiple delimiters *)
<Split> the <tokens> from the <code> by /[;,\s]+/.

(* Case-insensitive split *)
<Split> the <sections> from the <text> by /SECTION/i.
```

#### Split Behavior

- Returns an array of strings between delimiter matches
- Empty strings are included when delimiters are adjacent
- If no match is found, returns original string as single-element array
- Supports all regex flags

### 2.7 Validation Example

```aro
(Validate Registration: Form Handler) {
    <Extract> the <email> from the <form: email>.
    <Extract> the <phone> from the <form: phone>.

    (* Email validation *)
    match <email> {
        case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/ {
            <Log> "Valid email" to the <console>.
        }
        otherwise {
            <Return> a <BadRequest: status> with "Invalid email format".
        }
    }

    (* Phone validation - US format *)
    match <phone> {
        case /^\d{3}-\d{3}-\d{4}$/ {
            <Log> "Valid phone" to the <console>.
        }
        case /^\(\d{3}\)\s?\d{3}-\d{4}$/ {
            <Log> "Valid phone (parentheses)" to the <console>.
        }
        otherwise {
            <Return> a <BadRequest: status> with "Invalid phone format".
        }
    }

    <Return> an <OK: status> for the <validation>.
}
```

### 2.8 Lexer Disambiguation

When the lexer encounters `/`:
1. If followed by whitespace/newline: treat as division operator
2. Otherwise: scan as regex literal until unescaped `/`

```aro
(* Division - space after / *)
<Compute> the <result> from <a> / <b>.

(* Regex - no space, forms complete literal *)
case /pattern/ { ... }
where <field> matches /pattern/i.
```

---

## 3. Date and Time Handling

ARO provides native date/time support through the magic `<now>` variable, timezone handling, relative offsets, and date arithmetic.

### 3.1 The Magic `<now>` Variable

`<now>` is a built-in variable that resolves to the current timestamp:

```aro
<Log> <now> to the <console>.
(* Output: 2025-01-15T10:30:00Z *)
```

**Semantics:**
- Evaluates to current UTC time when accessed
- Returns an ISO 8601 formatted string
- Available in all feature sets without explicit declaration

### 3.2 Timezone Handling

By default, `<now>` returns UTC. Explicit timezone qualifiers are supported:

```aro
(* UTC (default) *)
<now>                      (* 2025-01-15T10:30:00Z *)
<now: UTC>                 (* 2025-01-15T10:30:00Z - explicit *)

(* Local system time *)
<now: local>               (* 2025-01-15T11:30:00+01:00 *)

(* Named timezone (IANA) *)
<now: Europe/Berlin>       (* 2025-01-15T11:30:00+01:00 *)
<now: America/New_York>    (* 2025-01-15T05:30:00-05:00 *)
<now: Asia/Tokyo>          (* 2025-01-15T19:30:00+09:00 *)
<now: Pacific/Auckland>    (* 2025-01-15T23:30:00+13:00 *)
```

### 3.3 Relative Date Offsets

Qualifiers on `<now>` (or any date variable) create relative dates:

```aro
<now: +1h>     (* 1 hour from now *)
<now: -3d>     (* 3 days ago *)
<now: +2w>     (* 2 weeks from now *)
<now: -6M>     (* 6 months ago *)
<now: +1y>     (* 1 year from now *)
```

#### Supported Units

| Short | Long | Description |
|-------|------|-------------|
| `s` | `seconds` | Seconds |
| `m` | `minutes`, `min` | Minutes |
| `h` | `hours` | Hours |
| `d` | `days` | Days |
| `w` | `weeks` | Weeks |
| `M` | `months` | Months |
| `y` | `years` | Years |

#### Combining Timezone and Offset

```aro
<now: Europe/Berlin, +1h>   (* Berlin time + 1 hour *)
<now: local, -30m>          (* Local time - 30 minutes *)
```

#### Relative to Any Date

```aro
<Extract> the <start-date> from the <project: start>.
<Compute> the <deadline: +14d> from <start-date>.  (* 14 days after start *)
```

### 3.4 Date Parsing

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

### 3.5 Date Arithmetic

ARO supports arithmetic operations on dates:

#### Adding Offsets

```aro
<Compute> the <due-date> from <start-date> + 14d.
<Compute> the <reminder> from <appointment> - 1h.
<Compute> the <extended-deadline> from <deadline> + 1w + 2d.
```

#### Subtracting Dates (Duration)

```aro
<Compute> the <duration> from <end-date> - <start-date>.
<duration: days>      (* Number of days between dates *)
<duration: hours>     (* Number of hours between dates *)
```

### 3.6 Date Ranges

Create date ranges using the `Create` action:

```aro
<Create> the <vacation: date-range> from <start-date> to <end-date>.
<Create> the <this-month: date-range> from <month-start> to <now>.
```

#### Span Extraction

Access the span of a date range using qualifiers:

```aro
<vacation: days>      (* Number of days in the range *)
<vacation: hours>     (* Number of hours *)
<vacation: minutes>   (* Number of minutes *)
<vacation: weeks>     (* Number of complete weeks *)
```

#### Range Properties

```aro
<vacation: start>     (* Start date of the range *)
<vacation: end>       (* End date of the range *)
```

### 3.7 Date Comparisons

Temporal comparison operators for use in conditions:

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

### 3.8 Distance Calculations

Calculate the distance between two dates:

```aro
<Compute> the <time-until: distance> from <now> to <deadline>.
<time-until: days>     (* Days until deadline *)
<time-until: hours>    (* Hours until deadline *)
```

If the first date is after the second, the result is negative.

### 3.9 Date Formatting

Format dates for display using format strings:

```aro
<Compute> the <formatted: format> from <date> with "MMM dd, yyyy".
(* Output: "Jan 15, 2025" *)

<Compute> the <time-display: format> from <now> with "HH:mm:ss".
(* Output: "10:30:00" *)

<Compute> the <full-datetime: format> from <date> with "yyyy-MM-dd'T'HH:mm:ss".
(* Output: "2025-01-15T10:30:00" *)
```

#### Format Specifiers

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

#### Locale Formatting

```aro
<Compute> the <german-date: format> from <date> with "dd.MM.yyyy".
(* Output: "15.01.2025" *)

<Compute> the <us-date: format> from <date> with "MM/dd/yyyy".
(* Output: "01/15/2025" *)
```

### 3.10 Date Object Properties

When a date is resolved, these properties are accessible via qualifiers:

```
+------------------+----------------------------------------+
| Property         | Description                            |
+------------------+----------------------------------------+
| iso              | ISO 8601 string                        |
| year             | 4-digit year (2025)                    |
| month            | Month number (1-12)                    |
| day              | Day of month (1-31)                    |
| hour             | Hour (0-23)                            |
| minute           | Minute (0-59)                          |
| second           | Second (0-59)                          |
| dayOfWeek        | Weekday name ("Wednesday")             |
| dayOfYear        | Day of year (1-366)                    |
| weekOfYear       | Week of year (1-53)                    |
| timestamp        | Unix timestamp in seconds              |
| timezone         | Timezone name ("UTC" or IANA)          |
+------------------+----------------------------------------+
```

**Access:**
```aro
<Extract> the <year> from the <now: year>.
<Extract> the <day-name> from the <appointment: dayOfWeek>.
<Extract> the <unix-time> from the <now: timestamp>.
```

### 3.11 Common Patterns

#### Token Expiration

```aro
(Create Token: Auth API) {
    <Create> the <token> with <user>.
    <Compute> the <expires-at: +7d> from <now>.

    <Store> the <session> with {
        token: <token>,
        created: <now>,
        expires: <expires-at>
    } into the <session-repository>.

    <Return> an <OK: status> with <session>.
}
```

#### Booking Validation

```aro
(Create Booking: Booking API) {
    <Extract> the <date-str> from the <request: date>.
    <Compute> the <booking-date: date> from <date-str>.

    (* Must book at least 24 hours in advance *)
    <Compute> the <min-time: +24h> from <now>.
    <Return> a <BadRequest: status> with "Must book 24 hours in advance"
        when <booking-date> before <min-time>.

    (* Cannot book more than 90 days out *)
    <Compute> the <max-time: +90d> from <now>.
    <Return> a <BadRequest: status> with "Cannot book more than 90 days ahead"
        when <booking-date> after <max-time>.

    <Create> the <booking> with {
        date: <booking-date>,
        created: <now>,
        status: "confirmed"
    }.

    <Return> an <OK: status> with <booking>.
}
```

#### Report Generation

```aro
(Monthly Report: Analytics) {
    (* Calculate date range for last 30 days *)
    <Compute> the <report-start: -30d> from <now>.
    <Create> the <report-period: date-range> from <report-start> to <now>.

    (* Get the span *)
    <Extract> the <days-count: days> from <report-period>.

    (* Retrieve records in range *)
    <Retrieve> the <orders> from the <order-repository>
        where <created> in <report-period>.

    <Compute> the <order-count: count> from <orders>.

    (* Format report date *)
    <Compute> the <report-date: format> from <now> with "MMMM dd, yyyy".

    <Return> an <OK: status> with {
        period: <report-period>,
        days: <days-count>,
        totalOrders: <order-count>,
        generatedAt: <report-date>
    }.
}
```

#### Cleanup Expired Records

```aro
(Cleanup Expired: Scheduled Task) {
    (* Find records older than 90 days *)
    <Retrieve> the <old-records> from the <record-repository>
        where <created> before <now: -90d>.

    for each <record> in <old-records> {
        <Delete> the <record> from the <record-repository>.
    }

    <Compute> the <deleted-count: count> from <old-records>.
    <Log> "Cleaned up expired records" to the <console>.

    <Return> an <OK: status> with { deleted: <deleted-count> }.
}
```

---

## 4. Complete Example

```aro
(Application-Start: DevOps Dashboard) {
    <Log> "Starting DevOps Dashboard..." to the <console>.
    <Start> the <http-server> with <contract>.
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}

(healthCheck: Health API) {
    (* Run system health checks *)
    <Execute> the <disk-check> with "df -h /".
    <Execute> the <memory-check> with "free -m".

    (* Check for errors *)
    <Create> the <health-status> with {
        disk: <disk-check: error> is false,
        memory: <memory-check: error> is false,
        timestamp: <now>
    }.

    match <disk-check: error> or <memory-check: error> {
        case true {
            <Return> a <ServerError: status> with <health-status>.
        }
        case false {
            <Return> an <OK: status> with <health-status>.
        }
    }
}

(searchLogs: Logs API) {
    <Extract> the <pattern> from the <request: pattern>.
    <Extract> the <since> from the <request: since>.

    (* Parse the since date *)
    <Compute> the <since-date: date> from <since>.

    (* Execute log search *)
    <Execute> the <search-result> with "grep -r '${pattern}' /var/log/app/".

    <Return> an <Error: status> with <search-result>
        when <search-result: error> is true.

    (* Split into lines and filter by pattern *)
    <Split> the <log-lines> from <search-result: output> by /\n/.

    (* Filter lines matching timestamp format after since-date *)
    <Filter> the <recent-lines> from <log-lines>
        where <line> matches /^\d{4}-\d{2}-\d{2}/.

    <Return> an <OK: status> with {
        pattern: <pattern>,
        since: <since-date>,
        matches: <recent-lines>,
        searchedAt: <now>
    }.
}

(validateInput: Input Validation) {
    <Extract> the <email> from the <request: email>.
    <Extract> the <code> from the <request: code>.

    (* Validate email format *)
    match <email> {
        case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
            <Log> "Valid email" to the <console>.
        }
        otherwise {
            <Return> a <BadRequest: status> with "Invalid email".
        }
    }

    (* Validate product code format: XX-0000 *)
    match <code> {
        case /^[A-Z]{2}-\d{4}$/ {
            <Log> "Valid product code" to the <console>.
        }
        otherwise {
            <Return> a <BadRequest: status> with "Invalid product code".
        }
    }

    <Return> an <OK: status> with { validated: true }.
}

(scheduleTask: Scheduler API) {
    <Extract> the <task-name> from the <request: name>.
    <Extract> the <delay-minutes> from the <request: delayMinutes>.

    (* Calculate scheduled time *)
    <Compute> the <offset> from "+" + <delay-minutes> + "m".
    <Compute> the <scheduled-at: ${offset}> from <now>.

    (* Format for display *)
    <Compute> the <display-time: format> from <scheduled-at> with "MMM dd, yyyy HH:mm".

    <Create> the <scheduled-task> with {
        name: <task-name>,
        createdAt: <now>,
        scheduledAt: <scheduled-at>,
        displayTime: <display-time>,
        status: "pending"
    }.

    <Store> the <scheduled-task> into the <task-repository>.

    <Return> an <OK: status> with <scheduled-task>.
}
```

---

## 5. Grammar Extensions

```ebnf
(* Regex Literal *)
regex_literal = "/" , pattern_body , "/" , [ flags ] ;
pattern_body  = { pattern_char | escaped_char } ;
pattern_char  = ? any character except "/" and newline ? ;
escaped_char  = "\\" , ? any character ? ;
flags         = { "i" | "s" | "m" | "g" } ;

(* Pattern in match statement *)
pattern = literal | variable_ref | wildcard | regex_literal ;

(* Date offset *)
relative_offset = ("+" | "-") , number , time_unit ;
time_unit       = "s" | "seconds" | "m" | "min" | "minutes"
                | "h" | "hours" | "d" | "days" | "w" | "weeks"
                | "M" | "months" | "y" | "years" ;

(* Timezone qualifier *)
timezone_qualifier = "UTC" | "local" | iana_timezone ;
iana_timezone      = region , "/" , city ;

(* Date comparisons *)
comparison_op     += "before" | "after" ;
existence_check   += expression , [ "not" ] , "in" , expression ;
```

---

## 6. Implementation Notes

### 6.1 Execute Action

```swift
public struct ExecuteAction: ActionImplementation {
    public static let role: ActionRole = .request
    public static let verbs: Set<String> = ["exec", "execute", "run", "shell"]
    public static let validPrepositions: Set<Preposition> = [.with, .for, .on]

    public func execute(
        result: ResultDescriptor,
        object: ObjectDescriptor,
        context: ExecutionContext
    ) async throws -> any Sendable {
        let config = try extractConfig(from: object, context: context)
        let execResult = try await runCommand(config)
        context.bind(result.base, value: execResult)
        return execResult
    }
}
```

### 6.2 Regex Matching

```swift
public func regexMatches(_ value: String, pattern: String, flags: String) -> Bool {
    var options: NSRegularExpression.Options = []
    if flags.contains("i") { options.insert(.caseInsensitive) }
    if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
    if flags.contains("m") { options.insert(.anchorsMatchLines) }

    guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
        return false
    }

    let range = NSRange(value.startIndex..., in: value)
    return regex.firstMatch(in: value, range: range) != nil
}
```

### 6.3 Date Service

```swift
public protocol DateService: Sendable {
    func now(timezone: String?) -> Date
    func parse(_ iso8601: String) throws -> Date
    func offset(_ date: Date, by: DateOffset) -> Date
    func distance(from: Date, to: Date) -> DateDistance
    func format(_ date: Date, pattern: String) -> String
    func createRange(from: Date, to: Date) -> DateRange
}

public struct DateOffset: Sendable {
    let value: Int
    let unit: DateUnit
}

public enum DateUnit: String, Sendable {
    case seconds, minutes, hours, days, weeks, months, years
}
```

### 6.4 Runtime Recognition of `<now>`

The runtime recognizes `now` as a special identifier:

```swift
func resolve(_ name: String, qualifiers: [String]) -> Any? {
    if name == "now" {
        let timezone = extractTimezone(qualifiers)
        let offset = extractOffset(qualifiers)
        var date = dateService.now(timezone: timezone)
        if let offset = offset {
            date = dateService.offset(date, by: offset)
        }
        return date
    }
    return variables[name]
}
```
