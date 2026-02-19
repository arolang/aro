# ARO-0037: Regex-Based String Splitting

* Proposal: ARO-0037
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0001, ARO-0004, ARO-0010

## Abstract

This proposal defines the Split action with regex-based delimiters using the `by` clause. Split enables string tokenization with powerful pattern matching for parsing text, CSV data, log files, and structured strings.

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
Extract the <first-name: first> from the <fields>.
Extract the <last-name: 1> from the <fields>.
```

### 4.2 Log Parsing

```aro
(* Parse log entry: "2024-01-15 10:30:45 INFO Server started" *)
Split the <parts> from the <log-line> by /\s+/.
Extract the <date: first> from the <parts>.
Extract the <time: 1> from the <parts>.
Extract the <level: 2> from the <parts>.
```

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

(* Split and get range *)
Split the <words> from the <sentence> by /\s+/.
Extract the <first-three: 0-2> from the <words>.
```

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

---

## References

- `Sources/ARORuntime/Actions/BuiltIn/SplitAction.swift` - Implementation
- `Examples/Split/` - Split action examples
- ARO-0010: Advanced Features - Regex support
