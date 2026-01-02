# Chapter 27: Control Flow

ARO provides control flow constructs for conditional execution. This chapter covers how to make decisions in your feature sets using guarded statements and match expressions.

## When Guards

The `when` clause conditionally executes a single statement. If the condition is false, the statement is skipped and execution continues to the next statement.

### Syntax

```aro
<Action> the <result> preposition the <object> when <condition>.
```

### Basic Guards

```aro
(getUser: User API) {
    <Extract> the <user-id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    (* Return NotFound only when user is empty *)
    <Return> a <NotFound: status> for the <missing: user> when <user> is empty.

    <Return> an <OK: status> with <user>.
}
```

### Guard Examples

```aro
(* Only return OK when count is not zero *)
<Return> an <OK: status> with <items> when <count> is not 0.

(* Send notification only when user has email *)
<Send> the <notification> to the <user: email> when <user: email> exists.

(* Log admin access only for admins *)
<Log> "admin access" to the <audit> when <user: role> = "admin".

(* Return error when validation fails *)
<Return> a <BadRequest: status> for the <invalid: input> when <validation> is failed.
```

### Comparison Operators

| Operator | Meaning |
|----------|---------|
| `is` | Equality |
| `is not` | Inequality |
| `is empty` | Null/empty check |
| `is not empty` | Has value |
| `exists` | Value exists |
| `is defined` | Value is defined |
| `is null` | Value is null |
| `>` | Greater than |
| `<` | Less than |
| `>=` | Greater than or equal |
| `<=` | Less than or equal |
| `=` | Equality |
| `!=` | Strict inequality |

### Boolean Operators

Combine conditions with `and`, `or`, `not`:

```aro
(* Multiple conditions with and *)
<Return> an <OK: status> with <user> when <user: active> is true and <user: verified> is true.

(* Either condition with or *)
<Return> a <BadRequest: status> for the <unavailable: product> when <stock> is empty or <stock> < <required>.

(* Negation *)
<Allow> the <access> for the <user> when not <user: banned>.

(* Complex condition *)
<Grant> the <admin-features> for the <user> when (<user: role> is "admin" or <user: is-owner> is true) and <resource: public> is false.
```

## Match Expressions

Pattern matching for multiple cases:

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
(PUT /orders/{id}/status: Order API) {
    <Extract> the <order-id> from the <pathParameters: id>.
    <Extract> the <new-status> from the <request: body.status>.
    <Retrieve> the <order> from the <order-repository> where id = <order-id>.

    match <new-status> {
        case "confirmed" {
            <Validate> the <order> for the <confirmation-rules>.
            <Emit> an <OrderConfirmed: event> with <order>.
        }
        case "shipped" {
            <Validate> the <order> for the <shipping-rules>.
            <Emit> an <OrderShipped: event> with <order>.
        }
        case "delivered" {
            <Emit> an <OrderDelivered: event> with <order>.
        }
        case "cancelled" {
            <Emit> an <OrderCancelled: event> with <order>.
        }
        otherwise {
            <Return> a <BadRequest: status> for the <invalid: status>.
        }
    }

    <Transform> the <updated-order> from the <order> with { status: <new-status> }.
    <Store> the <updated-order> into the <order-repository>.
    <Return> an <OK: status> with <updated-order>.
}
```

### HTTP Method Routing

```aro
match <http: method> {
    case "GET" {
        <Retrieve> the <resource> from the <database>.
    }
    case "POST" {
        <Create> the <resource> in the <database>.
    }
    case "PUT" {
        <Update> the <resource> in the <database>.
    }
    case "DELETE" {
        <Remove> the <resource> from the <database>.
    }
    otherwise {
        <Return> a <MethodNotAllowed: error> for the <request>.
    }
}
```

### Pattern Matching with Guards

```aro
match <user: subscription> {
    case <premium> where <user: credits> > 0 {
        <Grant> the <premium-features> for the <user>.
        <Deduct> the <credit> from the <user: account>.
    }
    case <premium> {
        <Notify> the <user> about the <low-credits>.
        <Grant> the <basic-features> for the <user>.
    }
    case <basic> {
        <Grant> the <basic-features> for the <user>.
    }
    otherwise {
        <Redirect> the <user> to the <subscription-page>.
    }
}
```

### Status Code Handling

```aro
match <status-code> {
    case 200 {
        <Parse> the <response: body> from the <http-response>.
        <Return> the <data> for the <request>.
    }
    case 404 {
        <Return> a <NotFound: error> for the <request>.
    }
    case 500 {
        <Log> "server error" to the <monitoring>.
        <Return> a <ServerError> for the <request>.
    }
    otherwise {
        <Return> an <UnknownError> for the <request>.
    }
}
```

### Regular Expression Patterns

Match statements support regex patterns for flexible string matching (see **Section 27.4** for comprehensive regex documentation):

```aro
match <message.text> {
    case /^ERROR:/i {
        <Log> <message.text> to the <console>.
        <Emit> an <AlertTriggered: event> with <message>.
    }
    case /^WARN:/i {
        <Log> <message.text> to the <console>.
    }
    case /^[A-Z]{3}-\d{4}$/ {
        (* Matches ticket IDs like "ABC-1234" *)
        <Process> the <ticket-reference> from the <message>.
    }
    otherwise {
        <Log> <message.text> to the <console>.
    }
}
```

Regex patterns use forward slashes (`/pattern/flags`) and support flags like `i` (case insensitive), `s` (dot matches newlines), and `m` (multiline). See Section 27.4 for more details and additional use cases.

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
    <Extract> the <text> from the <event: text>.

    match <text> {
        case /^\/help/i {
            <Send> "Available commands: /help, /status, /quit" to the <user>.
        }
        case /^\/status\s+(\w+)$/i {
            <Emit> a <StatusQuery: event> with <text>.
        }
        case /^\/quit/i {
            <Emit> a <UserDisconnected: event> with <user>.
        }
        case /https?:\/\/[\w.-]+/i {
            (* Contains a URL *)
            <Scan> the <link> for the <security-check>.
        }
        otherwise {
            <Store> the <text> into the <message-repository>.
        }
    }

    <Return> an <OK: status>.
}
```

### Using Regex in Filter Actions

Filter collections based on regex pattern matching with the `matches` operator:

```aro
(Filter Log Files: File Handler) {
    <Retrieve> the <files> from the <file-repository>.

    (* Filter for error log files *)
    <Filter> the <error-logs> from the <files> where name matches /error-\d{4}-\d{2}-\d{2}\.log$/i.

    (* Filter for IP addresses in text *)
    <Filter> the <ip-entries> from the <log-lines> where text matches /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/.

    <Return> an <OK: status> with <error-logs>.
}
```

### Using Regex in Where Clauses

Repository queries support regex matching:

```aro
(Search Users: User API) {
    (* Find users with email addresses from specific domains *)
    <Retrieve> the <users> from the <user-repository> where email matches /@(company|example)\.com$/i.

    (* Find tickets by pattern *)
    <Retrieve> the <tickets> from the <ticket-repository> where code matches /^PROJ-\d{4}$/.

    <Return> an <OK: status> with <users>.
}
```

### Using Regex with Split Action

Split strings using regex patterns:

```aro
(Parse CSV Line: Data Handler) {
    <Extract> the <line> from the <input>.

    (* Split by comma, optional whitespace *)
    <Split> the <fields> from the <line> with /\s*,\s*/.

    (* Split by multiple delimiters *)
    <Split> the <words> from the <text> with /[\s,;]+/.

    <Return> an <OK: status> with <fields>.
}
```

The Split action supports regex flags:

```aro
(* Case-insensitive split *)
<Split> the <parts> from the <text> with /AND|OR/i.

(* Multiline split *)
<Split> the <paragraphs> from the <document> with /\n\n+/m.
```

### Common Regex Patterns

#### Email Validation

```aro
match <email> {
    case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i {
        <Return> an <OK: status> with { valid: true }.
    }
    otherwise {
        <Return> a <BadRequest: status> with { error: "Invalid email format" }.
    }
}
```

#### URL Detection

```aro
match <text> {
    case /https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&\/=]*)/i {
        <Extract> the <url> from the <text>.
        <Validate> the <url> for the <security-check>.
    }
    otherwise {
        <Process> the <text> as the <plain-message>.
    }
}
```

#### Phone Number Validation

```aro
match <phone> {
    case /^\+?1?\d{9,15}$/ {
        <Return> an <OK: status> with { valid: true }.
    }
    case /^\(\d{3}\)\s*\d{3}-\d{4}$/ {
        (* US format: (555) 123-4567 *)
        <Return> an <OK: status> with { valid: true }.
    }
    otherwise {
        <Return> a <BadRequest: status> with { error: "Invalid phone number" }.
    }
}
```

#### Date Format Matching

```aro
match <date-string> {
    case /^\d{4}-\d{2}-\d{2}$/ {
        (* ISO format: 2024-12-25 *)
        <Parse> the <date> from the <date-string> with "yyyy-MM-dd".
    }
    case /^\d{2}\/\d{2}\/\d{4}$/ {
        (* US format: 12/25/2024 *)
        <Parse> the <date> from the <date-string> with "MM/dd/yyyy".
    }
    otherwise {
        <Return> a <BadRequest: status> with { error: "Unsupported date format" }.
    }
}
```

#### Command Parsing

```aro
match <input> {
    case /^\/set\s+(\w+)\s+(.+)$/i {
        (* Matches: /set key value *)
        <Extract> the <key> from the <input>.
        <Extract> the <value> from the <input>.
        <Store> the <value> into the <settings: key>.
    }
    case /^\/get\s+(\w+)$/i {
        (* Matches: /get key *)
        <Extract> the <key> from the <input>.
        <Retrieve> the <value> from the <settings: key>.
        <Return> an <OK: status> with <value>.
    }
    otherwise {
        <Return> a <BadRequest: status> with { error: "Unknown command" }.
    }
}
```

#### Log Level Filtering

```aro
<Filter> the <error-logs> from the <logs> where message matches /^\[ERROR\]/i.
<Filter> the <warning-logs> from the <logs> where message matches /^\[WARN(ING)?\]/i.
<Filter> the <critical-logs> from the <logs> where message matches /^\[(ERROR|FATAL|CRITICAL)\]/i.
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
        <Validate> the <email>.
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

Regex can be tricky. Test patterns with sample data:

```aro
(* Test different email formats *)
match "user@example.com" { case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i { ... } }  (* ✓ *)
match "user.name+tag@example.co.uk" { case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i { ... } }  (* ✓ *)
match "invalid@" { case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i { ... } }  (* ✗ *)
```

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
(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Validate> the <user-data> for the <user-schema>.

    <Return> a <BadRequest: status> with <validation: errors> when <validation> is failed.

    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}
```

### Find-or-404

```aro
(GET /products/{id}: Product API) {
    <Extract> the <product-id> from the <pathParameters: id>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.

    <Return> a <NotFound: status> for the <missing: product> when <product> is empty.

    <Return> an <OK: status> with <product>.
}
```

### Check-Permission

```aro
(DELETE /posts/{id}: Post API) {
    <Extract> the <post-id> from the <pathParameters: id>.
    <Retrieve> the <post> from the <post-repository> where id = <post-id>.

    <Return> a <NotFound: status> for the <missing: post> when <post> is empty.

    <Return> a <Forbidden: status> for the <unauthorized: deletion>
        when <post: authorId> is not <current-user: id> and <current-user: role> is not "admin".

    <Delete> the <post> from the <post-repository> where id = <post-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

### Fail Fast with Guards

Check error conditions early with guarded returns:

```aro
(POST /transfer: Banking) {
    <Extract> the <amount> from the <request: body.amount>.
    <Extract> the <from-account> from the <request: body.from>.
    <Extract> the <to-account> from the <request: body.to>.

    (* Early exits for invalid input *)
    <Return> a <BadRequest: status> for the <invalid: amount> when <amount> <= 0.
    <Return> a <BadRequest: status> for the <same: accounts> when <from-account> is <to-account>.

    <Retrieve> the <source> from the <account-repository> where id = <from-account>.

    <Return> a <NotFound: status> for the <missing: source-account> when <source> is empty.
    <Return> a <BadRequest: status> for the <insufficient: funds> when <source: balance> < <amount>.

    (* Now proceed with transfer *)
    <Retrieve> the <destination> from the <account-repository> where id = <to-account>.
    <Transfer> the <amount> from the <source> to the <destination>.
    <Return> an <OK: status> for the <transfer>.
}
```

### Conditional Processing

```aro
(POST /orders: Order API) {
    <Extract> the <order-data> from the <request: body>.
    <Create> the <order> with <order-data>.

    (* Conditional discount *)
    <Compute> the <discount> with <order: total> * 0.1 when <order: total> >= 100.
    <Transform> the <order> from the <order> with { discount: <discount> } when <discount> exists.

    (* Conditional express shipping *)
    <Compute> the <express-fee> for the <order> when <order: express> is true.
    <Transform> the <order> from the <order> with { shippingFee: <express-fee> } when <express-fee> exists.

    <Store> the <order> into the <order-repository>.
    <Return> a <Created: status> with <order>.
}
```

## Complete Example

```aro
(User Authentication: Security) {
    <Require> the <request> from the <framework>.
    <Require> the <user-repository> from the <framework>.

    (* Extract credentials *)
    <Extract> the <username> from the <request: body>.
    <Extract> the <password> from the <request: body>.

    (* Validate input - guarded return *)
    <Return> a <BadRequest: error> for the <request>
        when <username> is empty or <password> is empty.

    (* Look up user *)
    <Retrieve> the <user> from the <user-repository>.

    (* Handle user not found - guarded statements *)
    <Log> <username> to the <console> when <user> is null.
    <Return> an <Unauthorized: error> for the <request> when <user> is null.

    (* Check account status with match *)
    match <user: status> {
        case "locked" {
            <Return> an <AccountLocked: error> for the <request>.
        }
        case "pending" {
            <Send> the <verification-email> to the <user: email>.
            <Return> a <PendingVerification: status> for the <request>.
        }
        case "active" {
            (* Verify password *)
            <Compute> the <password-hash> for the <password>.

            match <password-hash> {
                case <user: password-hash> {
                    <Create> the <session-token> for the <user>.
                    <Log> <user> to the <console>.
                    <Return> an <OK: status> with the <session-token>.
                }
                otherwise {
                    <Increment> the <failed-attempts> for the <user>.
                    <Lock> the <user: account> for the <security-policy>
                        when <failed-attempts> >= 5.
                    <Return> an <Unauthorized: error> for the <request>.
                }
            }
        }
        otherwise {
            <Return> an <InvalidAccountStatus: error> for the <request>.
        }
    }
}
```

## Best Practices

### Use Guards for Early Exits

Guards with `when` are ideal for:
- Input validation
- Preconditions
- Error returns

```aro
(* Good - guards for early exit *)
<Return> a <BadRequest: status> for the <missing: id> when <user-id> is empty.
<Return> a <NotFound: status> for the <missing: user> when <user> is empty.
<Return> a <Forbidden: status> for the <private: profile> when <user: private> is true.

(* Continue with main logic *)
<Return> an <OK: status> with <user>.
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
    case "pending" { ... }
    case "processing" { ... }
    case "shipped" { ... }
    case "delivered" { ... }
    otherwise { ... }
}
```

### Be Explicit in Conditions

```aro
(* Good - explicit conditions *)
<Grant> the <access> for the <user> when <user: active> is true and <user: verified> is true.

(* Avoid - implicit truthiness *)
<Grant> the <access> for the <user> when <user: active> and <user: verified>.
```

---

*Next: Chapter 28 — Data Pipelines*
