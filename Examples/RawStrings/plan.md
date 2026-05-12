# Build a raw string literals demo

Create a single-file ARO application that demonstrates raw string literals using single quotes (ARO-0060). Single quotes prevent escape sequence processing.

In the `Application-Start` feature set:

1. **Regex patterns** -- Compare double-quoted `"\\d+\\.\\d+\\.\\d+"` (requires escaping) with single-quoted `'\d+\.\d+\.\d+'` (no escaping needed).
2. **Windows file paths** -- Compare `"C:\\Users\\Admin\\config.json"` with `'C:\Users\Admin\config.json'`.
3. **UNC network paths** -- `'\\server\share\data\file.txt'`.
4. **LaTeX commands** -- `'\documentclass{article}'`, `'\frac{1}{2}'`.
5. **Escape comparison** -- Double quotes process `\n` as newline; single quotes keep `\n` literal.

Log all comparisons and return OK.
