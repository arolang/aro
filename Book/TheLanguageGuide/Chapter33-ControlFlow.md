# Chapter 33: Control Flow

ARO provides control flow constructs for conditional execution and iteration. This chapter covers how to make decisions in your feature sets using guarded statements and match expressions, and how to iterate over collections and numeric ranges.

## When Guards

The `when` clause conditionally executes a single statement. If the condition is false, the statement is skipped and execution continues to the next statement.

### Syntax

```aro
Action the <result> preposition the <object> when <condition>.
```

### Basic Guards

```aro
(getUser: User API) {
    Extract the <user-id> from the <pathParameters: id>.
    Retrieve the <found> from the <user-repository> where <id> = <user-id>.

    (* A filtered Retrieve that matches nothing binds [], not null — so test
       the count. See the note under Comparison Operators. *)
    Compute the <match-count: length> from <found>.
    Return a <NotFound: status> for the <missing: user> when <match-count> == 0.

    Return an <OK: status> with <found>.
}
```

### Guard Examples

```aro
(* Only return OK when count is not zero *)
Return an <OK: status> with <items> when <count> != 0.

(* Send notification only when user has email *)
Send the <notification> to the <user: email> when <user: email> exists.

(* Log admin access only for admins *)
Log "admin access" to the <audit> when <user: role> == "admin".

(* Return error when validation fails *)
Return a <BadRequest: status> for the <invalid: input> when <validation> is failed.
```

### Comparison Operators

| Operator | Meaning |
|----------|---------|
| `==` / `=` | Equality |
| `!=` | Inequality |
| `>` | Greater than |
| `<` | Less than |
| `>=` | Greater than or equal |
| `<=` | Less than or equal |
| `exists` | Value exists (postfix, e.g. `<user: email> exists`) |
| `is true` / `is false` | Boolean check |
| `is null` | Null check |
| `is a Type` | Type check (e.g. `<value> is a Number`) |
| `contains` | Membership |
| `matches` | Regex match |
| `in` / `not in` | Member of a collection or date range |
| `starts with` / `ends with` | Literal prefix / suffix |
| `before` / `after` | Instant ordering |

> **Note:** In a `when` guard, `is` only works for `is true`, `is false`,
> `is null`, and type checks. For value equality use `==` (or `=`), not
> `is`. (Inside a repository `where` clause the `is` keyword *does*
> read as equality, e.g. `where <status> is "active"`.)
>
> **`is null` does not catch an empty query result.** A filtered `Retrieve`
> that matches nothing binds an empty list, and `[]` is neither null nor
> absent — so `when <user> is null` never fires for it, and neither does
> `exists`. To branch on "no rows", compute the length and compare it to
> zero, or give the `Retrieve` a `default` clause (Chapter 36) so there is
> always something to work with. `is null` remains the right test for a
> value that really can be null, such as an absent field in a parsed body.

### Affix and Membership Guards

```aro
Log "routed to the API" to the <console> when <path> starts with "/api".
Log "an ARO source file" to the <console> when <name> ends with ".aro".
Log "allowed" to the <console> when <tag> not in <banned>.
```

These read the same in a `when` guard and in a `where` clause. They used not
to: `where` had `in` and `not in`, `when` had only `in`, and neither had the
affix operators — so a prefix test in a guard was written as
`matches "^/api"`. That is a regex, and it quietly accepts more than it looks
like it does: `matches "^a.c"` is true of `axc` as well as `a.c`. The affix
operators are literal, which is the whole reason to have them.

`starts` and `ends` are not reserved words. Only a following `with`, in
operator position, makes them operators, so `<starts>`, `<ends>` and
`<start-date>` remain names you can use. Likewise a bare `not` is still
negation; only the pair `not in` is an operator.

### Boolean Operators

Combine conditions with `and`, `or`, `not`:

```aro
(* Multiple conditions with and *)
Return an <OK: status> with <user> when <user: active> is true and <user: verified> is true.

(* Either condition with or *)
Return a <BadRequest: status> for the <unavailable: product> when <stock> is null or <stock> < <required>.

(* Negation — the field has to exist; reading an absent one is an error,
   not a false *)
Log "access granted" to the <console> when not <user: banned>.

(* Complex condition *)
Emit an <AdminAccess: event> with <user> when (<user: role> == "admin" or <user: owner> is true) and <resource: public> is false.
```

## Match Expressions

Pattern matching for multiple cases:

<div style="text-align: center; margin: 2em 0;">
<svg width="500" height="210" viewBox="0 0 500 210" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Input value box -->
  <rect x="175" y="10" width="150" height="34" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="250" y="32" text-anchor="middle" font-size="12" fill="#4338ca">input value</text>

  <!-- Arrow from input to match -->
  <line x1="250" y1="44" x2="250" y2="72" stroke="#1f2937" stroke-width="2"/>
  <polygon points="250,72 245,62 255,62" fill="#1f2937"/>

  <!-- Match decision box -->
  <rect x="175" y="72" width="150" height="34" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="250" y="94" text-anchor="middle" font-size="12" fill="#ffffff">match</text>

  <!-- Arrow left to case "a" -->
  <line x1="175" y1="89" x2="90" y2="89" stroke="#1f2937" stroke-width="2"/>
  <line x1="90" y1="89" x2="90" y2="130" stroke="#1f2937" stroke-width="2"/>
  <polygon points="90,130 85,120 95,120" fill="#1f2937"/>

  <!-- Arrow center to case "b" -->
  <line x1="250" y1="106" x2="250" y2="130" stroke="#1f2937" stroke-width="2"/>
  <polygon points="250,130 245,120 255,120" fill="#1f2937"/>

  <!-- Arrow right to case _ -->
  <line x1="325" y1="89" x2="410" y2="89" stroke="#1f2937" stroke-width="2"/>
  <line x1="410" y1="89" x2="410" y2="130" stroke="#1f2937" stroke-width="2"/>
  <polygon points="410,130 405,120 415,120" fill="#1f2937"/>

  <!-- case "a" box (green) -->
  <rect x="35" y="130" width="110" height="30" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="90" y="150" text-anchor="middle" font-size="11" fill="#166534">case "a"</text>

  <!-- case "b" box (amber) -->
  <rect x="195" y="130" width="110" height="30" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="250" y="150" text-anchor="middle" font-size="11" fill="#92400e">case "b"</text>

  <!-- case _ box (gray) -->
  <rect x="355" y="130" width="110" height="30" rx="4" fill="#f3f4f6" stroke="#9ca3af" stroke-width="2"/>
  <text x="410" y="150" text-anchor="middle" font-size="11" fill="#374151">case _ (default)</text>

  <!-- Arrows from case boxes to execute blocks -->
  <line x1="90" y1="160" x2="90" y2="178" stroke="#1f2937" stroke-width="2"/>
  <polygon points="90,178 85,168 95,168" fill="#1f2937"/>

  <line x1="250" y1="160" x2="250" y2="178" stroke="#1f2937" stroke-width="2"/>
  <polygon points="250,178 245,168 255,168" fill="#1f2937"/>

  <line x1="410" y1="160" x2="410" y2="178" stroke="#1f2937" stroke-width="2"/>
  <polygon points="410,178 405,168 415,168" fill="#1f2937"/>

  <!-- Execute block labels -->
  <text x="90" y="196" text-anchor="middle" font-size="9" fill="#374151">execute block</text>
  <text x="250" y="196" text-anchor="middle" font-size="9" fill="#374151">execute block</text>
  <text x="410" y="196" text-anchor="middle" font-size="9" fill="#374151">execute block</text>
</svg>
</div>

```aro
match <value> {
    case <pattern> {
        (* handle this case *)
    }
    case <pattern> where <condition> {
        (* handle case with guard *)
    }
    otherwise {
        (* handle all other cases *)
    }
}
```

### Simple Value Matching

```aro
(updateOrderStatus: Order API) {
    Extract the <order-id> from the <pathParameters: id>.
    Extract the <new-status> from the <request: body.status>.
    Retrieve the <order> from the <order-repository> where <id> = <order-id>.

    match <new-status> {
        case "confirmed" {
            Validate the <confirmation> for the <order>.
            Emit an <OrderConfirmed: event> with <order>.
        }
        case "shipped" {
            Validate the <shipment> for the <order>.
            Emit an <OrderShipped: event> with <order>.
        }
        case "delivered" {
            Emit an <OrderDelivered: event> with <order>.
        }
        case "cancelled" {
            Emit an <OrderCancelled: event> with <order>.
        }
        otherwise {
            Return a <BadRequest: status> for the <invalid: status>.
        }
    }

    Transform the <updated-order> from the <order> with { status: <new-status> }.
    Store the <updated-order> into the <order-repository>.
    Return an <OK: status> with <updated-order>.
}
```

### HTTP Method Routing

```aro
match <http: method> {
    case "GET" {
        Retrieve the <resource> from the <database>.
    }
    case "POST" {
        Create the <resource> with <data>.
    }
    case "PUT" {
        Update the <resource> with <data>.
    }
    case "DELETE" {
        Remove the <resource> from the <database>.
    }
    otherwise {
        Return a <MethodNotAllowed: error> for the <request>.
    }
}
```

### Matching a Field

The subject of a `match` is a variable, so extract the field you want to branch
on first. Cases match *values* — string, number or boolean literals — and
`otherwise` catches the rest.

```aro
Extract the <tier> from the <user: subscription>.

match <tier> {
    case "premium" {
        Emit a <PremiumFeaturesGranted: event> with <user>.
    }
    case "basic" {
        Emit a <BasicFeaturesGranted: event> with <user>.
    }
    otherwise {
        Emit a <SubscriptionRequired: event> with <user>.
    }
}
```

### Status Code Handling

```aro
match <status-code> {
    case 200 {
        Parse the <response: body> from the <http-response>.
        Return the <data> for the <request>.
    }
    case 404 {
        Return a <NotFound: error> for the <request>.
    }
    case 500 {
        Log "server error" to the <monitoring>.
        Return a <ServerError> for the <request>.
    }
    otherwise {
        Return an <UnknownError> for the <request>.
    }
}
```

### Regular Expression Patterns

Match statements support regex patterns for flexible string matching (the **Regular Expression Matching** section below covers regex in full):

```aro
match <message: text> {
    case /^ERROR:/i {
        Log <message: text> to the <console>.
        Emit an <AlertTriggered: event> with <message>.
    }
    case /^WARN:/i {
        Log <message: text> to the <console>.
    }
    case /^[A-Z]{3}-\d{4}$/ {
        (* Matches ticket IDs like "ABC-1234" *)
        Emit a <TicketReferenced: event> with <message>.
    }
    otherwise {
        Log <message: text> to the <console>.
    }
}
```

Regex patterns use forward slashes (`/pattern/flags`) and support flags like `i` (case insensitive), `s` (dot matches newlines), and `m` (multiline). The next section covers the flags and the other places regex appears.

## Regular Expression Matching

ARO provides first-class support for regular expressions through regex literals. Regular expressions are powerful pattern-matching tools for string validation, extraction, and filtering.

### Regex Literal Syntax

Regular expressions use forward-slash delimiters with optional flags:

```
/pattern/flags
```

Examples:
- `/hello/` - Match "hello" (case-sensitive)
- `/hello/i` - Match "hello", "HELLO", "Hello" (case-insensitive)
- `/^[A-Z]{3}-\d{4}$/` - Match ticket IDs like "ABC-1234"
- `/error/im` - Match "error" with case-insensitive, multiline mode

### Regex Flags

| Flag | Name | Description |
|------|------|-------------|
| `i` | Case Insensitive | Match regardless of case (A = a) |
| `s` | Dotall | Dot (`.`) matches newlines |
| `m` | Multiline | `^` and `$` match line boundaries, not just string boundaries |

Combine flags by concatenating them: `/pattern/ims`

### Using Regex in Match Statements

Match statements are the primary place to use regex for branching logic:

```aro
(Process Message: Chat Handler) {
    Extract the <text> from the <event: text>.

    match <text> {
        case /^\/help/i {
            Send "Available commands: /help, /status, /quit" to the <user>.
        }
        case /^\/status\s+(\w+)$/i {
            Emit a <StatusQuery: event> with <text>.
        }
        case /^\/quit/i {
            Emit a <UserDisconnected: event> with <user>.
        }
        case /https?:\/\/[\w.-]+/i {
            (* Contains a URL *)
            Emit a <LinkPosted: event> with { text: <text> }.
        }
        otherwise {
            Store the <text> into the <message-repository>.
        }
    }

    Return an <OK: status> for the <message>.
}
```

### Using Regex in Filter Actions

Filter collections based on regex pattern matching with the `matches` operator:

```aro
(Filter Log Files: File Handler) {
    Retrieve the <files> from the <file-repository>.

    (* Filter for error log files *)
    Filter the <error-logs> from the <files> where <name> matches /error-\d{4}-\d{2}-\d{2}\.log$/i.

    (* Filter for IP addresses in text *)
    Filter the <ip-entries> from the <log-lines> where <text> matches /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/.

    Return an <OK: status> with <error-logs>.
}
```

### Using Regex in Where Clauses

Repository queries support regex matching:

```aro
(Search Users: User API) {
    (* Find users with email addresses from specific domains *)
    Retrieve the <users> from the <user-repository> where <email> matches /@(company|example)\.com$/i.

    (* Find tickets by pattern *)
    Retrieve the <tickets> from the <ticket-repository> where <code> matches /^PROJ-\d{4}$/.

    Return an <OK: status> with <users>.
}
```

### Using Regex with Split Action

Split strings using regex patterns:

```aro
(Parse CSV Line: Data Handler) {
    Extract the <line> from the <input>.

    (* Split by comma, optional whitespace *)
    Split the <fields> from the <line> by /\s*,\s*/.

    (* Split by multiple delimiters *)
    Split the <words> from the <text> by /[\s,;]+/.

    Return an <OK: status> with <fields>.
}
```

The Split action supports regex flags:

```aro
(* Case-insensitive split *)
Split the <parts> from the <text> by /AND|OR/i.

(* Multiline split *)
Split the <paragraphs> from the <document> by /\n\n+/m.
```

### Common Regex Patterns

#### Email Validation

```aro
match <email> {
    case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
        Return an <OK: status> with { valid: true }.
    }
    otherwise {
        Return a <BadRequest: status> with { error: "Invalid email format" }.
    }
}
```

#### URL Detection

```aro
match <text> {
    case /https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/=]*)/i {
        Extract the <url> from the <text>.
        Validate the <checked-url> for the <url>.
    }
    otherwise {
        Log <text> to the <console>.
    }
}
```

#### Phone Number Validation

```aro
match <phone> {
    case /^\+?1?\d{9,15}$/ {
        Return an <OK: status> with { valid: true }.
    }
    case /^\(\d{3}\)\s*\d{3}-\d{4}$/ {
        (* US format: (555) 123-4567 *)
        Return an <OK: status> with { valid: true }.
    }
    otherwise {
        Return a <BadRequest: status> with { error: "Invalid phone number" }.
    }
}
```

#### Date Format Matching

```aro
match <date-string> {
    case /^\d{4}-\d{2}-\d{2}$/ {
        (* ISO format: 2024-12-25 *)
        Parse the <date> from the <date-string> with "yyyy-MM-dd".
    }
    case /^\d{2}\/\d{2}\/\d{4}$/ {
        (* US format: 12/25/2024 *)
        Parse the <date> from the <date-string> with "MM/dd/yyyy".
    }
    otherwise {
        Return a <BadRequest: status> with { error: "Unsupported date format" }.
    }
}
```

#### Command Parsing

```aro
match <input> {
    case /^\/set\s+(\w+)\s+(.+)$/i {
        (* Matches: /set key value *)
        Extract the <key> from the <input>.
        Extract the <value> from the <input>.
        Store the <value> into the <settings: key>.
    }
    case /^\/get\s+(\w+)$/i {
        (* Matches: /get key *)
        Extract the <key> from the <input>.
        Retrieve the <value> from the <settings: key>.
        Return an <OK: status> with <value>.
    }
    otherwise {
        Return a <BadRequest: status> with { error: "Unknown command" }.
    }
}
```

#### Log Level Filtering

```aro
Filter the <error-logs> from the <logs> where <message> matches /^\[ERROR\]/i.
Filter the <warning-logs> from the <logs> where <message> matches /^\[WARN(ING)?\]/i.
Filter the <critical-logs> from the <logs> where <message> matches /^\[(ERROR|FATAL|CRITICAL)\]/i.
```

### Best Practices

#### Use Anchors for Exact Matching

```aro
(* Good - requires full match *)
match <ticket-id> {
    case /^[A-Z]{3}-\d{4}$/ {
        (* Matches ONLY "ABC-1234" format *)
    }
}

(* Risky - matches substrings *)
match <ticket-id> {
    case /[A-Z]{3}-\d{4}/ {
        (* Matches "ABC-1234" anywhere in the string *)
    }
}
```

#### Escape Special Characters

Regex special characters need escaping: `. ^ $ * + ? { } [ ] \ | ( )`

```aro
(* Match literal dots in domain names *)
match <domain> {
    case /^example\.com$/ {
        (* Correct - \. matches literal dot *)
    }
}

(* Match literal parentheses in phone numbers *)
match <phone> {
    case /^\(\d{3}\) \d{3}-\d{4}$/ {
        (* \( and \) match literal parentheses *)
    }
}
```

#### Keep Patterns Readable

```aro
(* Good - clear intent *)
match <email> {
    case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
        Validate the <checked> for the <email>.
    }
}

(* Avoid - overly complex *)
match <email> {
    case /^(?:[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9]))\.){3}(?:(2(5[0-5]|[0-4][0-9])|1[0-9][0-9]|[1-9]?[0-9])|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])$/i {
        (* Too complex - prefer simpler patterns for business logic *)
    }
}
```

#### Test Your Patterns

Regex can be tricky. The subject of a `match` must be a variable, so bind a
sample value first, then match it:

```aro
(* Bind a sample address, then test it against the pattern *)
Create the <sample> with "user@example.com".
match <sample> {
    case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
        (* ✓ matches — "user@example.com" is valid *)
    }
    otherwise {
        (* ✗ no match *)
    }
}
```

Other inputs worth testing against the same pattern: `"user.name+tag@example.co.uk"`
(✓ valid) and `"invalid@"` (✗ no match).

### Regex in ARO vs Other Languages

ARO's regex literals are inspired by JavaScript and Ruby:

| Language | Syntax | Example |
|----------|--------|---------|
| ARO | `/pattern/flags` | `/hello/i` |
| JavaScript | `/pattern/flags` | `/hello/i` |
| Ruby | `/pattern/flags` | `/hello/i` |
| Python | `r"pattern"` + flags param | `re.compile(r"hello", re.I)` |
| Java | `"pattern"` + flags param | `Pattern.compile("hello", Pattern.CASE_INSENSITIVE)` |

ARO's syntax prioritizes readability and inline usage within statements.

## Common Patterns

### Validate-or-Fail

```aro
(createUser: User API) {
    Extract the <user-data> from the <request: body>.
    Validate the <validation> for the <user-data>.

    Return a <BadRequest: status> with <validation: errors> when <validation> is failed.

    Create the <user> with <user-data>.
    Store the <user> into the <user-repository>.
    Return a <Created: status> with <user>.
}
```

### Find-or-404

```aro
(getProduct: Product API) {
    Extract the <product-id> from the <pathParameters: id>.
    Retrieve the <product> from the <product-repository> where <id> = <product-id>.

    Compute the <match-count: length> from <product>.
    Return a <NotFound: status> for the <missing: product> when <match-count> == 0.

    Return an <OK: status> with <product>.
}
```

### Check-Permission

```aro
(deletePost: Post API) {
    Extract the <post-id> from the <pathParameters: id>.
    Retrieve the <post> from the <post-repository> where <id> = <post-id>
        default { authorId: "" }.

    Extract the <author> from the <post: authorId>.
    Return a <NotFound: status> for the <missing: post> when <author> == "".

    Return a <Forbidden: status> for the <unauthorized: deletion>
        when <author> != <current-user: id> and <current-user: role> != "admin".

    Delete the <removed-post> from the <post-repository> where <id> = <post-id>.
    Return a <NoContent: status> for the <deletion>.
}
```

### Fail Fast with Guards

Check error conditions early with guarded returns:

```aro
(transferFunds: Banking) {
    Extract the <amount> from the <request: body.amount>.
    Extract the <source-id> from the <request: body.source>.
    Extract the <target-id> from the <request: body.target>.

    (* Early exits for invalid input *)
    Return a <BadRequest: status> for the <invalid: amount> when <amount> <= 0.
    Return a <BadRequest: status> for the <same: accounts> when <source-id> == <target-id>.

    Retrieve the <source> from the <account-repository> where <id> = <source-id>
        default { balance: -1 }.

    Extract the <balance> from the <source: balance>.
    Return a <NotFound: status> for the <missing: source-account> when <balance> < 0.
    Return a <BadRequest: status> for the <insufficient: funds> when <balance> < <amount>.

    (* Now proceed with transfer *)
    Retrieve the <destination> from the <account-repository> where <id> = <target-id>.
    Emit a <FundsTransferred: event> with {
        source: <source-id>, target: <target-id>, amount: <amount>
    }.
    Return an <OK: status> for the <transfer>.
}
```

### Conditional Processing

```aro
(createOrder: Order API) {
    Extract the <order-data> from the <request: body>.
    Create the <order> with <order-data>.
    Extract the <total> from the <order: total>.

    (* Conditional discount - only computed when the order qualifies.
       Arithmetic operands must be plain variables, so extract the field first. *)
    Compute the <discount> from <total> * 0.1 when <total> >= 100.

    (* Fold in the discount when present. Transform binds a NEW name -
       variables are immutable. *)
    Transform the <discounted-order> from the <order> with { discount: <discount> } when <discount> exists.

    (* Conditional express shipping *)
    Compute the <express-fee> for the <order> when <order: express> is true.
    Transform the <priced-order> from the <discounted-order> with { shippingFee: <express-fee> } when <express-fee> exists.

    Store the <priced-order> into the <order-repository>.
    Return a <Created: status> with <priced-order>.
}
```

## Complete Example

```aro
(loginUser: Security) {
    (* Extract credentials *)
    Extract the <body> from the <request: body>.
    Extract the <username> from the <body: username>.
    Extract the <password> from the <body: password>.

    (* Validate input - guarded return *)
    Return a <BadRequest: error> for the <request>
        when <username> is null or <password> is null.

    (* Look up user *)
    Retrieve the <found> from the <user-repository> where <name> = <username>.

    (* Handle user not found - an unmatched query binds [], so count it *)
    Compute the <match-count: length> from <found>.
    Log <username> to the <console> when <match-count> == 0.
    Return an <Unauthorized: error> for the <request> when <match-count> == 0.

    (* A where-filtered Retrieve that matches one row binds that row, not a
       one-element list, so read it directly. *)
    Create the <user> with <found>.

    (* Check account status with match *)
    match <user: status> {
        case "locked" {
            Return an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            Send the <verification-email> to the <user: email>.
            Return a <PendingVerification: status> for the <request>.
        }
        case "active" {
            (* Verify password *)
            Compute the <password-hash> for the <password>.

            match <password-hash> {
                case <user: password-hash> {
                    Create the <session-token> for the <user>.
                    Log <user> to the <console>.
                    Return an <OK: status> with the <session-token>.
                }
                otherwise {
                    Emit a <LoginFailed: event> with <user>.
                    Return an <Unauthorized: error> for the <request>.
                }
            }
        }
        otherwise {
            Return an <InvalidAccountStatus: error> for the <request>.
        }
    }
}
```

## Iteration

ARO supports two forms of loops: collection iteration and numeric range iteration.

### Collection Iteration

The `for each` loop processes every element in a collection:

```aro
for each <item> in <items> {
    Log <item> to the <console>.
}
```

Each iteration runs in an isolated child context. Variables bound inside the loop body do not leak out, and the loop variable (`<item>`) cannot be rebound within an iteration.

### Indexed Iteration

When you need the position of each element, use `at <idx>`:

```aro
for each <line> at <idx> in <lines> {
    Compute the <numbered> from <idx> ++ ": " ++ <line>.
    Log <numbered> to the <console>.
}
```

The `<idx>` variable is zero-based and bound automatically by the runtime for each iteration. This eliminates the need for a manual counter repository pattern.

### Numeric Range Iteration

For loops over a range of integers, use the `from ... to` syntax:

```aro
for <i> from 0 to 10 {
    Log <i> to the <console>.
}
```

The range is **inclusive at the start, exclusive at the end** (like Swift's `0..<10`). The variable `<i>` receives each integer in sequence.

This is especially useful when you need a numeric index but are not iterating over an existing collection — for example, filling a fixed-height display panel:

```aro
Compute the <panel-height> from <term-rows> - 3.

for <ridx> from 0 to <panel-height> {
    Compute the <file-row> from <ridx> < <total-files>.
    match <file-row> {
        case true  { (* render file entry at <ridx> *) }
        case false { (* render empty padding row *) }
    }
}
```

This merges what would otherwise be two separate loops (one for file entries, one for padding) into a single unified loop.

### Reserved Words in Variable Names

The following words are reserved and cannot stand **alone** as a variable name:
`on`, `in`, `is`, `with`, `at`, `for`, `from`, `to`. `<with>` is a preposition,
not a name.

Inside a **hyphenated** name they are ordinary words, because nothing but the
rest of the name can follow a hyphen: `<is-active>`, `<from-date>`,
`<created-at>`, `<content-type>` and `<valid-from>` all parse, as do
object-literal keys and qualifier path segments spelled that way —
`{ created-at: … }`, `<request: headers.Content-Type>`.

They used to fail everywhere, which forced fields to be renamed `createdAt`
even when the payload called them `created-at`, and left a real header name
like `Content-Type` unreachable (GitLab #579, #583).

---

## Best Practices

### Use Guards for Early Exits

Guards with `when` are ideal for:
- Input validation
- Preconditions
- Error returns

```aro
(* Good - guards for early exit *)
Return a <BadRequest: status> for the <missing: id> when <user-id> == "".
Return a <NotFound: status> for the <missing: user> when <match-count> == 0.
Return a <Forbidden: status> for the <private: profile> when <user: private> is true.

(* Continue with main logic *)
Return an <OK: status> with <user>.
```

### Use Match for Multiple Outcomes

Match expressions are ideal for:
- Status handling
- Role-based logic
- State machines
- Multiple distinct cases

```aro
(* Good - match for multiple cases *)
match <order: status> {
    case "pending" { (* ... *) }
    case "processing" { (* ... *) }
    case "shipped" { (* ... *) }
    case "delivered" { (* ... *) }
    otherwise { (* ... *) }
}
```

### Be Explicit in Conditions

```aro
(* Good - explicit conditions *)
Log "access granted" to the <console> when <user: active> is true and <user: verified> is true.

(* Avoid - implicit truthiness *)
Log "access granted" to the <console> when <user: active> and <user: verified>.
```

---

*Next: Chapter 34 — Data Pipelines*
