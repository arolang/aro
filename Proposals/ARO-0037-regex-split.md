# ARO-0037: Regex-Based String Splitting

* Proposal: ARO-0037
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0010

## Abstract

This proposal defines the Split action with regex-based delimiters using the `by` clause. Split enables string tokenization with powerful pattern matching for parsing text, CSV data, log files, and structured strings.

The delimiter goes after `by` — never `with`. Because `with` is the payload
preposition everywhere else, `Split … with ","` is the first spelling people
try; it is rejected at check time with a hint naming `by` (GitLab #513).

---

## 1. Syntax

### 1.1 Basic Split

```aro
Split the <result> from the <source> by /pattern/.
```

Where:
- `result` is the variable to bind the resulting array
- `source` is the string variable to split
- `/pattern/` is a regex delimiter

### 1.2 With Regex Flags

```aro
Split the <result> from the <source> by /pattern/flags.
```

Supported flags:
- `i` - Case-insensitive matching
- `s` - Dotall mode (`.` matches newlines)
- `m` - Multiline mode (`^` and `$` match line boundaries)
- `g` - Global (applies to all matches, default for split)

---

## 2. Examples

### 2.1 Simple Delimiter

```aro
(* Split CSV line by comma *)
Create the <csv-line> with "apple,banana,cherry".
Split the <fruits> from the <csv-line> by /,/.
(* fruits = ["apple", "banana", "cherry"] *)
```

### 2.2 Whitespace Splitting

```aro
(* Split by any whitespace *)
Create the <sentence> with "hello   world   foo".
Split the <words> from the <sentence> by /\s+/.
(* words = ["hello", "world", "foo"] *)
```

### 2.3 Multiple Delimiters

```aro
(* Split by comma, semicolon, or whitespace *)
Create the <mixed> with "a,b;c d".
Split the <tokens> from the <mixed> by /[,;\s]+/.
(* tokens = ["a", "b", "c", "d"] *)
```

### 2.4 Case-Insensitive Split

```aro
(* Split by "SECTION" regardless of case *)
Create the <text> with "Part1SECTIONPart2sectionPart3".
Split the <parts> from the <text> by /section/i.
(* parts = ["Part1", "Part2", "Part3"] *)
```

### 2.5 Path Splitting

```aro
(* Split file path by directory separator *)
Create the <path> with "/usr/local/bin/aro".
Split the <components> from the <path> by /\//.
(* components = ["", "usr", "local", "bin", "aro"] *)
```

---

## 3. Behavior

### 3.1 Result Type

Split always returns an array of strings:

```aro
Split the <parts> from the <input> by /,/.
(* parts: List<String> *)
```

### 3.2 No Match Behavior

If the pattern doesn't match, the original string is returned as a single-element array:

```aro
Create the <text> with "no-commas-here".
Split the <parts> from the <text> by /,/.
(* parts = ["no-commas-here"] *)
```

### 3.3 Empty Strings

Empty strings are included when delimiters are adjacent:

```aro
Create the <data> with "a,,b".
Split the <parts> from the <data> by /,/.
(* parts = ["a", "", "b"] *)
```

### 3.4 Leading/Trailing Delimiters

Leading or trailing delimiters produce empty strings:

```aro
Create the <csv> with ",a,b,".
Split the <parts> from the <csv> by /,/.
(* parts = ["", "a", "b", ""] *)
```

---

## 4. Common Patterns

### 4.1 CSV Parsing

```aro
(* Parse CSV line *)
Create the <line> with "John,Doe,30,Engineer".
Split the <fields> from the <line> by /,/.
Extract the <first-name: first> from the <fields>.   (* John *)
Extract the <role: 0> from the <fields>.             (* Engineer *)
Extract the <age: 1> from the <fields>.              (* 30 *)
```

> **A numeric index counts back from the end** (ARO-0038): `0` is the last
> element, `1` the one before it. `first` and `last` mean what they say and are
> unaffected. The examples in this section used to read `<last-name: 1>` as
> though `1` were the second element from the front, which binds `30` (GitLab
> #831).

### 4.2 Log Parsing

```aro
(* Parse log entry: "2024-01-15 10:30:45 INFO Server started" *)
Split the <parts> from the <log-line> by /\s+/.
Extract the <date: first> from the <parts>.
Extract the <message: 0> from the <parts>.       (* "started" — the last field *)
Extract the <subject: 1> from the <parts>.       (* "Server" *)
```

Fields counted from the front, in a record whose tail varies in length, are a
job for `Group` or a `match`, not for numeric specifiers — which is the practical
consequence of indexing from the end.

### 4.3 URL Query String

```aro
(* Parse query string: "name=John&age=30&city=NYC" *)
Split the <pairs> from the <query-string> by /&/.
for each <pair> in <pairs> {
    Split the <kv> from the <pair> by /=/.
    Extract the <key: first> from the <kv>.
    Extract the <value: last> from the <kv>.
}
```

### 4.4 Multi-line Text

```aro
(* Split text into lines *)
Split the <lines> from the <text> by /\r?\n/.
```

---

## 5. Regex Pattern Reference

### 5.1 Character Classes

| Pattern | Matches |
|---------|---------|
| `\s` | Whitespace |
| `\S` | Non-whitespace |
| `\d` | Digit |
| `\w` | Word character |
| `.` | Any character (except newline) |
| `[abc]` | Character set |
| `[^abc]` | Negated set |

### 5.2 Quantifiers

| Pattern | Meaning |
|---------|---------|
| `+` | One or more |
| `*` | Zero or more |
| `?` | Zero or one |
| `{n}` | Exactly n |
| `{n,m}` | Between n and m |

### 5.3 Anchors

| Pattern | Meaning |
|---------|---------|
| `^` | Start of string/line |
| `$` | End of string/line |

---

## 6. Integration with Element Access

Split pairs naturally with list element access (ARO-0038):

```aro
(* Split and extract first element *)
Split the <parts> from the <path> by /\//.
Extract the <filename: last> from the <parts>.

(* Split and get a range — also counted from the end, and in that order *)
Split the <words> from the <sentence> by /\s+/.
Extract the <last-three: 0-2> from the <words>.
```

---

## 7. Capture Groups

`Split` throws away what the delimiter matched. A pattern with capture groups
is how you get at the parts of a match rather than the parts around it, and
until GitLab #858 nothing in ARO could read one back: a named group compiled,
matched, and was then unreachable. The crawler chapter of *ARO by Example*
replaced one match with four `Split` statements, which is slower and wrong at
the edges.

Two Compute qualifiers read a match. Both take their pattern from the same
`by /pattern/flags` clause `Split` uses — there is one regex spelling in the
language, and a second would be one to get wrong.

### 7.1 `captures` — the first match

```aro
Create the <line> with "host=example.com".
Compute the <parts: captures> from the <line> by /(?<key>\w+)=(?<value>\S+)/.
(* parts = { match: "host=example.com", key: "host", value: "example.com",
             "1": "host", "2": "example.com" } *)
```

The record holds:

| Key | Value |
|-----|-------|
| `match` | the whole matched text |
| a group's name | what that named group matched |
| `"1"`, `"2"`, … | what each numbered group matched, named or not |

Named and numbered spellings both appear, because a pattern mixes them freely
and a reader should not have to count parentheses to find out that `key` is
also `1`.

### 7.2 `all-captures` — every match

```aro
Create the <line> with "host=example.com port=8080".
Compute the <pairs: all-captures> from the <line> by /(?<key>\w+)=(?<value>\S+)/.
(* pairs = [ { match: "host=example.com", key: "host", … },
             { match: "port=8080", key: "port", … } ] *)

for each <pair> in <pairs> {
    Log "${<pair: key>} -> ${<pair: value>}" to the <console>.
}
```

Repeated matching is the same operation over a different extent, so it is the
same action with a different qualifier rather than a second verb. A list of the
records `captures` binds is the only shape that composes with `for each`,
`length` and the rest of the collection vocabulary.

### 7.3 What a non-match binds

**`captures` binds an empty record; `all-captures` binds an empty list.**
Neither fails.

This follows the call ARO-0006 already makes for a `Retrieve` that matches
nothing (GitLab #835): finding nothing is an answer, not an error, and the
program guards on it.

```aro
Compute the <parts: captures> from the <line> by /(?<key>\w+)=(?<value>.*)/.
Compute the <found: length> from <parts>.
Log "unparsed: ${<line>}" to the <console> when <found> is 0.
```

A group that took part in no match — the unmatched branch of an alternation —
is **absent** from the record rather than present and empty. The difference
between "matched the empty string" and "did not participate" is exactly the one
a caller needs, and an absent key is how ARO says the second.

### 7.4 Flags

The same four as `Split`: `i`, `s`, `m`, `g`. `g` is implied by
`all-captures` and ignored by `captures`, which reads the first match by
definition.

---

## Grammar Extension

```ebnf
split_statement = "<Split>" , "the" , "<" , result , ">" ,
                  "from" , "the" , "<" , source , ">" ,
                  "by" , regex_literal , "." ;

regex_literal = "/" , pattern , "/" , [ flags ] ;
pattern = (* regex pattern *) ;
flags = { "i" | "s" | "m" | "g" } ;
```

---

## Summary

| Aspect | Description |
|--------|-------------|
| **Action** | `<Split>` |
| **Syntax** | `Split the <r> from the <s> by /pattern/flags.` |
| **Result** | `List<String>` |
| **No match** | Returns single-element array with original string |
| **Flags** | `i` (case-insensitive), `s` (dotall), `m` (multiline) |
| **Capture groups** | `Compute the <r: captures> from the <s> by /…/.` — §7 |
| **Non-match (captures)** | An empty record; an empty list for `all-captures` |

---

## References

- `Sources/ARORuntime/Actions/BuiltIn/SplitAction.swift` - Implementation
- `Sources/ARORuntime/Actions/BuiltIn/ComputeAction.swift` - `captures` / `all-captures` (§7)
- `Examples/Split/` - Split action examples
- ARO-0010: Advanced Features - Regex support
