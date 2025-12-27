# ARO-0037: Regular Expression Literals

* Proposal: ARO-0037
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0004

## Abstract

This proposal adds regular expression literal syntax (`/pattern/flags`) to ARO, enabling regex pattern matching in match statements and where clauses.

## Motivation

String matching is fundamental to many business applications. Currently, ARO provides:
- Exact string matching in match statements
- The `contains` operator for substring checks
- The `matches` operator with string patterns

However, developers often need more sophisticated pattern matching:
1. **Format Validation**: Email, phone numbers, identifiers
2. **Data Extraction**: Parse structured text
3. **Flexible Matching**: Case-insensitive, multiline patterns
4. **Declarative Patterns**: Express patterns inline without escaping

---

## 1. Regex Literal Syntax

Regex literals use forward slashes as delimiters with optional flags:

```aro
/pattern/flags
```

### Examples

```aro
(* Simple pattern *)
/^hello/

(* Pattern with flags *)
/^[a-z]+$/i

(* Pattern with escaped characters *)
/path\/to\/file/

(* Complex pattern *)
/^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i
```

### Flags

| Flag | Description | NSRegularExpression Option |
|------|-------------|---------------------------|
| `i` | Case insensitive | `.caseInsensitive` |
| `s` | Dot matches newlines | `.dotMatchesLineSeparators` |
| `m` | Multiline (^ and $ match line boundaries) | `.anchorsMatchLines` |
| `g` | Global (reserved for future replace operations) | - |

---

## 2. Match Statement with Regex

Regex patterns can be used as case patterns in match statements:

```aro
match <message.text> {
    case /^[a-z]+\-?[0-9]?$/ {
        <Log> the <message> for the <console> with "Matches format".
    }
    case /^ERROR:/i {
        <Log> the <error> for the <console> with <message.text>.
    }
    case "exact string" {
        (* Exact string match *)
    }
    otherwise {
        (* No match *)
    }
}
```

### Execution Semantics

- Regex patterns are tested using `NSRegularExpression.firstMatch`
- A match succeeds if any part of the string matches the pattern
- Use `^` and `$` anchors for full-string matching
- Cases are evaluated in order; first match wins

---

## 3. Where Clause with Regex

Regex literals work with the `matches` operator in where clauses:

```aro
<Retrieve> the <users> from the <user-repository>
    where <name> matches /Frodo\s+.*$/i.

<Filter> the <valid-emails> from the <emails>
    where <address> matches /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/i.
```

### Comparison with String Patterns

```aro
(* Regex literal - flags supported *)
where <email> matches /^admin@/i

(* String pattern - no flags *)
where <email> matches "^admin@"
```

---

## 4. Grammar Extension

```ebnf
(* Regex literal token *)
regex_literal = "/" , pattern_body , "/" , [ flags ] ;
pattern_body = { pattern_char | escaped_char } ;
pattern_char = ? any character except "/" and newline ? ;
escaped_char = "\\" , ? any character ? ;
flags = { "i" | "s" | "m" | "g" } ;

(* Pattern in match statement *)
pattern = literal | variable_ref | wildcard | regex_literal ;

(* Expression for where clause *)
primary_expression = ... | regex_literal | ... ;
```

---

## 5. Lexer Behavior

When the lexer encounters `/`:
1. Check if followed by whitespace/newline → treat as division operator
2. Otherwise, attempt to scan as regex literal:
   - Scan until unescaped `/`
   - Capture optional flags (i, s, m, g)
   - Backtrack to division if no closing `/` on same line

### Disambiguation

```aro
(* Division - space after / *)
<Compute> the <result> from <a> / <b>.

(* Regex - no space, forms complete literal *)
case /pattern/ { ... }
where <field> matches /pattern/i.
```

---

## 6. Runtime Implementation

### Pattern Matching (Match Statement)

```swift
case .regex(let pattern, let flags):
    guard let stringValue = value as? String else { return false }
    return regexMatches(stringValue, pattern: pattern, flags: flags)
```

### Expression Evaluation (Where Clause)

```swift
private func matchesPattern(_ value: any Sendable, _ pattern: any Sendable) -> Bool {
    // Handle regex dictionary (pattern + flags)
    if let regexDict = pattern as? [String: any Sendable],
       let p = regexDict["pattern"] as? String {
        let flags = (regexDict["flags"] as? String) ?? ""
        return regexMatches(str, pattern: p, flags: flags)
    }
    // Handle string pattern (no flags)
    ...
}
```

### Flag Mapping

```swift
var options: NSRegularExpression.Options = []
if flags.contains("i") { options.insert(.caseInsensitive) }
if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
if flags.contains("m") { options.insert(.anchorsMatchLines) }
```

---

## 7. Error Handling

| Error | Behavior |
|-------|----------|
| Empty regex `//` | Lexer returns slash token (not a regex) |
| Unclosed regex `/pattern` | Lexer returns slash token (not a regex) |
| Invalid regex syntax | Runtime returns `false` for match |
| Non-string value | Pattern match returns `false` |

---

## 8. Examples

### Email Validation

```aro
(validateEmail: Form Validation) {
    <Extract> the <email> from the <form: email>.

    match <email> {
        case /^[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}$/ {
            <Return> an <OK: status> with { valid: true }.
        }
        otherwise {
            <Return> a <BadRequest: status> with { error: "Invalid email format" }.
        }
    }
}
```

### Message Routing

```aro
(routeMessage: Message Handler) {
    <Extract> the <content> from the <message: content>.

    match <content> {
        case /^\/help/i {
            <Emit> a <HelpRequested: event> with <message>.
        }
        case /^\/status\s+(\w+)$/i {
            <Emit> a <StatusQuery: event> with <message>.
        }
        case /^ERROR:/i {
            <Log> the <error: alert> for the <console> with <content>.
        }
        otherwise {
            <Emit> a <MessageReceived: event> with <message>.
        }
    }
}
```

### Filtering with Regex

```aro
(listAdminUsers: User API) {
    <Retrieve> the <users> from the <user-repository>
        where <email> matches /^admin@|@admin\./i.

    <Return> an <OK: status> with <users>.
}
```

---

## 9. Future Work

- **Capture Groups**: Extract matched substrings
- **Replace Action**: `<Replace> the <result> in <string> matching /pattern/ with <replacement>`
- **Split by Regex**: `<Split> the <parts> from <string> by /delimiter/`

---

## Summary

ARO-0037 adds regex literal syntax `/pattern/flags` for:
- Match statement case patterns
- Where clause `matches` operator
- Flags: `i` (case-insensitive), `s` (dotall), `m` (multiline), `g` (global)

This enables expressive pattern matching while maintaining ARO's readable syntax.
