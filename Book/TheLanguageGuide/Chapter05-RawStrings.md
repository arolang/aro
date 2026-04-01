# Chapter 5: String Literals

*"Write what you mean. Let the quotes signal the intent."*

---

## 5.1 One Rule, Two Quote Types

ARO has exactly two kinds of string literals, distinguished solely by which quote character encloses them:

| Quote | Type | Backslash treatment |
|-------|------|---------------------|
| `"..."` | Regular string | Escape sequences processed (`\n` → newline, `\t` → tab, …) |
| `'...'` | Raw string | Backslashes are literal — only `\'` has special meaning |

The distinction is intentional and permanent. There is no flag, no prefix, no contextual mode — the opening quote character completely determines how the content is interpreted. This makes the choice explicit and readable at a glance.

```aro
Log "Hello\nWorld" to the <console>.    (* prints on two lines *)
Log 'Hello\nWorld' to the <console>.    (* prints: Hello\nWorld *)
```

The two strings look nearly identical. The behavior is completely different.

---

<div style="text-align: center; margin: 2em 0;">
<svg width="520" height="190" viewBox="0 0 520 190" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Regular string box -->
  <rect x="20" y="20" width="200" height="76" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="120" y="40" text-anchor="middle" font-size="11" font-weight="bold" fill="#4338ca">Regular String</text>
  <text x="120" y="57" text-anchor="middle" font-size="10" fill="#4338ca" font-family="monospace">"Hello\nWorld"</text>
  <text x="120" y="76" text-anchor="middle" font-size="9" fill="#4338ca">escape sequences interpreted</text>
  <text x="120" y="90" text-anchor="middle" font-size="9" fill="#4338ca">\n → newline, \t → tab, ...</text>
  <!-- Raw string box -->
  <rect x="300" y="20" width="200" height="76" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>
  <text x="400" y="40" text-anchor="middle" font-size="11" font-weight="bold" fill="#92400e">Raw String</text>
  <text x="400" y="57" text-anchor="middle" font-size="10" fill="#92400e" font-family="monospace">'Hello\nWorld'</text>
  <text x="400" y="76" text-anchor="middle" font-size="9" fill="#92400e">literal backslash-n</text>
  <text x="400" y="90" text-anchor="middle" font-size="9" fill="#92400e">only \' is special</text>
  <!-- Arrows down -->
  <line x1="120" y1="96" x2="120" y2="130" stroke="#9ca3af" stroke-width="2"/>
  <polygon points="115,130 120,140 125,130" fill="#9ca3af"/>
  <line x1="400" y1="96" x2="400" y2="130" stroke="#9ca3af" stroke-width="2"/>
  <polygon points="395,130 400,140 405,130" fill="#9ca3af"/>
  <!-- Runtime output boxes -->
  <rect x="20" y="140" width="200" height="36" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="120" y="157" text-anchor="middle" font-size="10" fill="#ffffff" font-family="monospace">Hello</text>
  <text x="120" y="170" text-anchor="middle" font-size="10" fill="#ffffff" font-family="monospace">World</text>
  <rect x="300" y="140" width="200" height="36" rx="4" fill="#1f2937" stroke="#1f2937" stroke-width="2"/>
  <text x="400" y="163" text-anchor="middle" font-size="10" fill="#ffffff" font-family="monospace">Hello\nWorld</text>
</svg>
</div>

## 5.2 Regular Strings

Regular strings, enclosed in double quotes, process escape sequences. A backslash followed by a recognised escape character is replaced with the corresponding value at parse time:

| Escape | Meaning |
|--------|---------|
| `\n` | Newline |
| `\t` | Horizontal tab |
| `\r` | Carriage return |
| `\\` | Literal backslash |
| `\"` | Literal double quote |
| `\'` | Literal single quote |
| `\0` | Null character |
| `\$` | Literal dollar sign (prevents interpolation) |
| `\u{XXXX}` | Unicode scalar (1–8 hex digits) |

Any escape sequence not in the table above is a lexer error:

```
error: Invalid escape sequence '\d' in string literal
```

### String Interpolation

Regular strings support `${...}` expressions that embed variable values directly into the string. The expression inside the braces is evaluated and converted to a string:

```aro
Create the <name> with "Alice".
Create the <count> with 42.
Log "Hello, ${<name>}! You have ${<count>} messages." to the <console>.
(* Prints: Hello, Alice! You have 42 messages. *)
```

Any variable reference or expression can appear inside `${...}`. This is the only place where `$` has special meaning — to include a literal `$` followed by `{` in a regular string, use `\$`:

```aro
Log "Price: \${<amount>}" to the <console>.    (* Prints: Price: ${<amount>} *)
Log "Price: ${<amount>}" to the <console>.     (* Prints: Price: 99.99    *)
```

### Unicode Escapes

The `\u{...}` escape inserts any Unicode scalar value. The braces contain 1 to 8 hexadecimal digits:

```aro
Log "Caf\u{e9}" to the <console>.          (* Café *)
Log "\u{1F600}" to the <console>.          (* 😀 *)
Log "\u{2603}" to the <console>.           (* ☃ snowman *)
```

### Single-Line Constraint

Regular strings must fit on a single line. A newline character inside a double-quoted string is a lexer error. Use `\n` to embed a newline:

```aro
Log "line one\nline two" to the <console>.   (* correct *)
Log "line one
line two" to the <console>.                  (* ERROR: unterminated string *)
```

---

## 5.3 Raw Strings

Raw strings, enclosed in single quotes, treat backslashes as ordinary characters. The parser does not interpret any escape sequence except `\'`, which produces a literal single quote so the string can contain the quote character without ending prematurely.

```aro
Create the <pattern> with '\d+\.\d+'.        (* stored as: \d+\.\d+   *)
Create the <path> with 'C:\Users\Admin'.      (* stored as: C:\Users\Admin *)
Create the <formula> with '\frac{1}{2}'.      (* stored as: \frac{1}{2}    *)
```

What you type is what you get — no translation, no surprises.

### Only One Escape: `\'`

The single backslash-escape supported in raw strings is `\'`:

```aro
Create the <message> with 'it\'s a raw string'.
(* stored as: it's a raw string *)
```

Every other backslash sequence is stored verbatim. `'\n'` is two characters: a backslash and the letter `n`. `'\t'` is two characters: a backslash and the letter `t`.

### No Interpolation

Raw strings do **not** support `${...}` interpolation. The `$` character is always treated as a literal dollar sign:

```aro
Create the <name> with "Alice".

Log '${<name>}' to the <console>.    (* Prints: ${<name>} — NOT Alice *)
Log "${<name>}" to the <console>.    (* Prints: Alice               *)
```

This is the most significant practical difference between the two string types. If you need to embed a variable into a string, you must use a double-quoted string for the parts that contain the interpolation, then concatenate with `++` if needed:

```aro
Create the <path-prefix> with 'C:\Users\'.
Create the <username> with "Alice".
Compute the <full-path> from <path-prefix> ++ <username> ++ '\Documents'.
(* Result: C:\Users\AliceDocuments *)
```

### Single-Line Constraint

Like regular strings, raw strings must fit on one line. A newline inside a raw string is a lexer error.

---

## 5.4 Choosing Between the Two Types

The decision is simple:

**Use single quotes (`'...'`) when:**
- The string contains backslashes that should be literal
- You are writing a regex pattern
- You are writing a Windows or UNC file path
- You are writing LaTeX, TeX, or troff content
- You are writing a SQL query with backslash escapes
- You are writing a shell command with backslashes

**Use double quotes (`"..."`) when:**
- The string needs escape sequences (`\n`, `\t`, etc.)
- The string uses `${...}` interpolation
- The string contains no backslashes at all (either type works; convention favours double quotes)

When in doubt: if you see a backslash in the content, use single quotes. If you need a newline or tab, use double quotes. If the string is plain text with no special characters, either works — the community convention is double quotes for plain text.

---

## 5.5 Use Cases for Raw Strings

### Regex Patterns

Regex syntax uses backslashes heavily — `\d` for digits, `\w` for word characters, `\.` for a literal dot. With raw strings, you write the pattern exactly as it appears in a regex reference:

```aro
(* Without raw strings: every backslash must be doubled *)
Transform the <version> from <text> with regex "\\d+\\.\\d+\\.\\d+".

(* With raw strings: pattern is readable *)
Transform the <version> from <text> with regex '\d+\.\d+\.\d+'.

(* Email pattern *)
Transform the <emails> from <body> with regex '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'.

(* ISO date: YYYY-MM-DD *)
Transform the <dates> from <text> with regex '\d{4}-\d{2}-\d{2}'.

(* Match or not match inside a match expression *)
match <input> {
    case '\d+' { Log "number" to the <console>. }
    case '\w+' { Log "word" to the <console>. }
}
```

Regex is the most common reason to reach for raw strings. The readability improvement is substantial for any non-trivial pattern.

### Windows File Paths

Windows paths use backslashes as directory separators. Raw strings eliminate the need to double every separator:

```aro
(* Regular string: each backslash doubled *)
Read the <config> from "C:\\Program Files\\MyApp\\config.json".

(* Raw string: natural Windows path *)
Read the <config> from 'C:\Program Files\MyApp\config.json'.
Read the <log> from 'D:\Logs\app-2026.log'.
```

### UNC Network Paths

UNC paths start with two backslashes. The raw string version is unambiguous:

```aro
Read the <data> from '\\server\share\reports\q1.xlsx'.
Read the <backup> from '\\nas01\backups\daily\latest.tar'.
```

With a regular string, the four leading backslashes (`\\\\`) make the path visually confusing. The raw string `'\\server\share'` contains exactly what it says.

### LaTeX and TeX Content

LaTeX commands begin with backslashes. Generating LaTeX output becomes natural:

```aro
Create the <doc-class> with '\documentclass[12pt]{article}'.
Create the <usepackage> with '\usepackage{amsmath}'.
Create the <begin-doc> with '\begin{document}'.
Create the <fraction> with '\frac{a}{b}'.
Create the <end-doc> with '\end{document}'.
```

### SQL with Backslash Escapes

Some SQL dialects use backslashes to escape special characters in `LIKE` patterns:

```aro
Create the <query> with 'SELECT * FROM files WHERE path LIKE "C:\\%"'.
Create the <pattern-query> with 'SELECT * FROM tags WHERE name REGEXP "\\d{4}-\\d{2}"'.
```

### Shell Commands

When building shell command strings for the `Exec` action, backslash is used for escaping in shell syntax:

```aro
Create the <cmd> with 'grep -E "\d+\.\d+" /var/log/app.log'.
Create the <awk-cmd> with 'awk -F: '\''{ print $1 }'\'' /etc/passwd'.
```

---

## 5.6 Mixing Both Types

Both string types produce the same runtime type — a plain string value. You can use them side by side and concatenate them freely:

```aro
Create the <base-path> with 'C:\Users\'.
Create the <username> with "Alice".
Create the <file> with '\Documents\report.txt'.
Compute the <full-path> from <base-path> ++ <username> ++ <file>.
(* C:\Users\Alice\Documents\report.txt *)
```

```aro
(* A regex pattern built from parts *)
Create the <prefix> with '\d{4}-'.
Create the <month> with '\d{2}-'.
Create the <day> with '\d{2}'.
Compute the <date-pattern> from <prefix> ++ <month> ++ <day>.
(* \d{4}-\d{2}-\d{2} *)
```

Mixing is valid and sometimes the clearest choice — raw strings for backslash-heavy segments, regular strings for parts that need escapes or interpolation.

---

## 5.7 Common Mistakes

**Forgetting that `\n` is literal in raw strings:**

```aro
(* This logs the six characters: H e l l o \ n W o r l d *)
Log 'Hello\nWorld' to the <console>.

(* This logs Hello on one line, World on the next *)
Log "Hello\nWorld" to the <console>.
```

**Trying to interpolate in a raw string:**

```aro
Create the <user> with "Alice".
Log 'Hello, ${<user>}!' to the <console>.   (* Logs: Hello, ${<user>}! *)
Log "Hello, ${<user>}!" to the <console>.   (* Logs: Hello, Alice!     *)
```

**Doubling backslashes in a context that doesn't need it:**

```aro
(* Unnecessary — raw string already keeps backslashes literal *)
Transform <result> from <text> with regex '\\d+\\.\\d+'.
(* Matches: \\d+\\.\\d+ — probably not what you wanted *)

(* Correct *)
Transform <result> from <text> with regex '\d+\.\d+'.
```

**Using the wrong type for template content:**

```aro
(* LaTeX in a regular string — every backslash must be escaped *)
Create the <cmd> from "\\documentclass{article}\n\\begin{document}".

(* LaTeX sections with raw strings, newline with regular string *)
Create the <class> from '\documentclass{article}'.
Create the <begin> from '\begin{document}'.
Compute the <header> from <class> ++ "\n" ++ <begin>.
```

---

## 5.8 Quick Reference

```
"regular string"   — escape sequences active: \n \t \\ \" \u{XXXX}
                   — ${<var>} interpolation supported
                   — single-line only

'raw string'       — all backslashes literal except \'
                   — no ${} interpolation
                   — single-line only
```

| Need | Use |
|------|-----|
| Newlines, tabs | `"..."` with `\n`, `\t` |
| Variable interpolation | `"..."` with `${<var>}` |
| Regex patterns | `'...'` |
| Windows paths | `'...'` |
| UNC paths | `'...'` |
| LaTeX / TeX | `'...'` |
| Plain text (no special chars) | Either (convention: `"..."`) |
| Mix of both | Concatenate with `++` |

---

*Next: Chapter 6 — Feature Sets*
