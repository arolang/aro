# ARO-0060: Raw String Literals

* Proposal: ARO-0060
* Author: ARO Language Team
* Status: **Implemented**
* Related Issues: GitLab #109

## Abstract

Add raw string literals with r-prefix to prevent escape sequence processing, making regex patterns, file paths, and other backslash-heavy content more readable.

## Problem

Current string literals require escaping special characters like backslashes, which makes certain content difficult to read:

```aro
(* Writing a regex with many escapes *)
Transform the <result> from the <text> with regex "\\d+\\.\\d+".

(* Windows file path *)
Read the <config> from "C:\\Users\\Admin\\config.json".

(* JSON with quotes *)
Log "The user said: \"Hello\"" to <console>.
```

## Solution

Introduce raw string literals with r-prefix (Python/Rust style):

```aro
(* Regex without escapes *)
Transform the <result> from the <text> with regex r"\d+\.\d+".

(* Windows file path without escapes *)
Read the <config> from r"C:\Users\Admin\config.json".

(* Still need to escape quotes inside raw strings *)
Log r"Path: C:\Users\Admin" to <console>.
```

### Syntax

- **Raw string**: `r"content"`
- **No escape processing**: Backslashes are literal characters
- **Quote escaping**: Still need `\"` to include quotes in the string
- **Error**: `r"unclosed` produces lexer error

### Lexer Changes

```swift
// Detect r-prefix before string
case "r" where peek() == "\"":
    advance() // consume 'r'
    advance() // consume '"'
    return scanRawString()

private func scanRawString() -> Token {
    var value = ""
    while !isAtEnd && peek() != "\"" {
        if peek() == "\\" && peekNext() == "\"" {
            // Only allow \" escape in raw strings
            advance() // skip backslash
            value.append(advance()) // add quote
        } else {
            value.append(advance())
        }
    }
    // consume closing quote
    advance()
    return Token(.string, lexeme: "r\"...", literal: .string(value))
}
```

## Examples

### Regex Patterns
```aro
(Extract Versions: Version Extractor) {
    Extract the <text> from the <input>.
    Transform the <versions> from the <text> with regex r"\d+\.\d+\.\d+".
    Return an <OK: status> with <versions>.
}
```

### File Paths
```aro
(Read Windows Config: Config Loader) {
    Read the <config> from r"C:\Program Files\MyApp\config.json".
    Return an <OK: status> with <config>.
}
```

### Mixed Content
```aro
(Generate LaTeX: Report Generator) {
    (* Raw string for LaTeX commands *)
    Compute the <header> from r"\documentclass{article}".
    Compute the <formula> from r"\frac{1}{2}".
    Return an <OK: status> with <header>.
}
```

Fixes GitLab #109
