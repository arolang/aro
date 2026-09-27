# Read the capture groups of a regex match

Create an ARO application that parses `host=example.com port=8080 tls=on`
with one pattern rather than a chain of `Split` statements.

- `main.aro` — one `Application-Start` feature set that:
  - binds the line,
  - computes `<first: captures>` with `by /(?<key>\w+)=(?<value>\S+)/` and logs
    the named groups and the whole match,
  - computes `<settings: all-captures>` with the same pattern, logs how many
    matches there were, and iterates them logging `key -> value`,
  - computes `captures` with a pattern that does not match, and logs the size
    of the empty record it binds — showing that a non-match is an answer, not
    an error.
