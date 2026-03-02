# ARO-0060: Raw String Literals

* Proposal: ARO-0060
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #109

## Abstract

Use single quotes for raw string literals that prevent escape sequence processing, making regex patterns, file paths, and other backslash-heavy content more readable. Double quotes continue to process escape sequences.

## Problem

String literals with many backslashes require excessive escaping, making certain content difficult to read:

```aro
(* Writing a regex with many escapes *)
Transform the <result> from the <text> with regex "\\d+\\.\\d+".

(* Windows file path *)
Read the <config> from "C:\\Users\\Admin\\config.json".

(* LaTeX commands *)
Compute the <header> from "\\documentclass{article}".
```

## Solution

Introduce a simple, clean distinction between quote types:

- **Single quotes** `'...'` = raw strings (no escape processing except `\'`)
- **Double quotes** `"..."` = regular strings (full escape processing: `\n`, `\t`, `\\`, etc.)

```aro
(* Raw strings - no escaping needed *)
Transform the <result> from the <text> with regex '\d+\.\d+'.
Read the <config> from 'C:\Users\Admin\config.json'.
Compute the <header> from '\documentclass{article}'.

(* Regular strings - escapes work *)
Log "Hello\nWorld" to the <console>.
Log "Path: C:\\Users" to the <console>.
```

### Syntax

- **Raw string**: `'content'` - backslashes are literal, only `\'` needs escaping
- **Regular string**: `"content"` - full escape processing (`\n`, `\t`, `\\`, `\"`, etc.)
- **Error**: Unterminated strings produce lexer errors

### Lexer Changes

```swift
case "\"":
    // Double quotes: regular string with full escape processing
    try scanString(quote: char, start: startLocation)

case "'":
    // Single quotes: raw string (no escape processing except \')
    try scanRawString(quote: char, start: startLocation)

private func scanRawString(quote: Character, start: SourceLocation) throws {
    var value = ""
    while !isAtEnd && peek() != quote {
        if peek() == "\\" && peekNext() == quote {
            // Only allow \' escape in raw strings
            advance()  // skip backslash
            value.append(advance())  // add quote
        } else {
            value.append(advance())
        }
    }
    if isAtEnd {
        throw LexerError.unterminatedString(at: start)
    }
    advance()  // Closing quote
    addToken(.stringLiteral(value), start: start)
}
```

## Examples

### Regex Patterns
```aro
(Extract Versions: Version Extractor) {
    Extract the <text> from the <input>.
    (* Single quotes = raw string, no escaping needed *)
    Transform the <versions> from the <text> with regex '\d+\.\d+\.\d+'.
    Return an <OK: status> with <versions>.
}
```

### File Paths
```aro
(Read Windows Config: Config Loader) {
    (* Windows path with backslashes - no escaping needed *)
    Read the <config> from 'C:\Program Files\MyApp\config.json'.
    Return an <OK: status> with <config>.
}

(UNC Path: Network File) {
    (* UNC path with raw string *)
    Read the <data> from '\\server\share\document.txt'.
    Return an <OK: status> with <data>.
}
```

### LaTeX and Special Content
```aro
(Generate LaTeX: Report Generator) {
    (* Raw strings for LaTeX commands *)
    Compute the <header> from '\documentclass{article}'.
    Compute the <formula> from '\frac{1}{2}'.
    Compute the <package> from '\usepackage{amsmath}'.
    Return an <OK: status> with <header>.
}
```

### Mixed Usage
```aro
(Process Data: Data Handler) {
    (* Raw string for regex pattern *)
    Transform the <emails> from the <text> with regex '[a-z]+@[a-z]+\.[a-z]+'.

    (* Regular string with newline escape *)
    Log "Found emails:\n" to the <console>.

    (* Raw string for SQL *)
    Execute the <query> with sql 'SELECT * FROM users WHERE name LIKE "%\%%"'.

    Return an <OK: status> with <emails>.
}
```

Fixes GitLab #109
