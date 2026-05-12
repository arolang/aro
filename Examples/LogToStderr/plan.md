# Build a stderr/stdout stream routing demo

Create a single-file ARO application that demonstrates console stream routing with qualifiers.

In the `Application-Start` feature set:

1. **stdout (default)** -- `Log "message" to the <console>` goes to stdout. Explicitly: `Log "message" to the <console: output>`.

2. **stderr** -- `Log "message" to the <console: error>` routes to stderr. Show warning and error messages going to stderr.

3. **Data pipeline pattern** -- Output JSON data to stdout and progress/diagnostic messages to stderr, so they can be separated with shell redirection (`2> errors.txt 1> output.txt`).

4. **Backward compatibility** -- Show legacy syntax `Log "message" to the <stderr>` still works.
