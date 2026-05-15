# Build a multiline string literals demo

Create a single-file ARO application that demonstrates triple-quoted multiline string literals (ARO-0097).

In the `Application-Start` feature set:

1. Log a multiline string directly using triple quotes (`"""`).
2. Assign a multiline string (a SQL query) to a variable using `Create the <query> with """..."""`.
3. Show escape sequences work inside triple-quoted strings (tabs, escaped quotes).
4. Compute the length of a multiline string.

Log all results and return OK.
