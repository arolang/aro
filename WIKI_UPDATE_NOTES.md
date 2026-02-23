# Wiki Update Notes for ARO-0060 (Raw String Literals)

This document lists the wiki pages that need to be updated to reflect the new raw string literal syntax using single quotes.

## Summary of Changes

**New Syntax (ARO-0060):**
- `'...'` (single quotes) = raw strings - no escape processing except `\'`
- `"..."` (double quotes) = regular strings - full escape processing (`\n`, `\t`, `\\`, `\"`, etc.)

## Wiki Pages to Update

### 1. Language Fundamentals / Syntax Reference

Update any section discussing string literals to include both types:

**Before:**
> String literals are enclosed in double quotes and support escape sequences.

**After:**
> ARO supports two types of string literals:
> - **Double quotes** `"..."` create regular strings with full escape processing (`\n`, `\t`, `\\`, etc.)
> - **Single quotes** `'...'` create raw strings where backslashes are literal (only `\'` needs escaping)

### 2. Data Types / Primitives

Update the String type documentation:

```aro
(* Regular string with escape sequences *)
Log "Hello\nWorld" to the <console>.          (* Prints on two lines *)

(* Raw string - backslashes are literal *)
Transform <versions> from <text> with regex '\d+\.\d+\.\d+'.
Read <config> from 'C:\Users\Admin\config.json'.
```

### 3. Action Reference - Transform/Validate/Split

Add examples showing raw strings for regex patterns:

```aro
(* Use single quotes for regex patterns *)
Transform <emails> from <text> with regex '[a-z]+@[a-z]+\.[a-z]+'.
Split <parts> from <path> by /\\/.
```

### 4. File I/O Examples

Update file path examples to use raw strings:

```aro
(* Windows paths with raw strings *)
Read <config> from 'C:\Program Files\MyApp\config.json'.
Write <data> to '\\server\share\output.txt'.
```

### 5. Quick Start / Tutorial

Update any introductory examples to mention both string types:

- Use double quotes for messages and text with escape sequences
- Use single quotes for file paths, regex patterns, and backslash-heavy content

### 6. FAQ / Common Patterns

Add a new FAQ entry:

**Q: When should I use single quotes vs double quotes?**

**A:** Use single quotes `'...'` when you need backslashes to be literal (file paths, regex, LaTeX). Use double quotes `"..."` when you need escape sequences like `\n` or `\t`.

## References

- Proposal: `Proposals/ARO-0060-raw-string-literals.md`
- Example: `Examples/RawStrings/main.aro`
- Book Updates:
  - `Book/TheLanguageGuide/Chapter04-StatementAnatomy.md`
  - `Book/TheLanguageGuide/Chapter35-TypeSystem.md`

## Implementation Status

✅ Lexer updated
✅ Proposal written
✅ Tests updated
✅ Example created
✅ Book chapters updated
⏳ Wiki updates pending (external wiki - manual update required)
