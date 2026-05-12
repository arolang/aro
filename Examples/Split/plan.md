# Build a string splitting demo with regex delimiters

Create a single-file ARO application that demonstrates the `Split` action (ARO-0037) for splitting strings using regex delimiters.

In the `Application-Start` feature set:

1. Split CSV data by comma: `Split the <fruits> from the <csv-line> by /,/`.
2. Split by whitespace regex: `Split the <words> from the <sentence> by /\s+/`.
3. Split by multiple delimiters: `Split the <parts> from the <mixed-delimiters> by /[;,\s]+/`.

Log each result.
