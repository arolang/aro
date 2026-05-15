# Build a sink syntax demo

Create a single-file ARO application that demonstrates sink syntax (ARO-0043) where expressions are placed directly in the result position without creating a variable binding.

In the `Application-Start` feature set, show the contrast between standard and sink syntax:

- Standard: `Log the <message> to the <console>` (uses "the" + name).
- Sink with string literal: `Log "Starting up..." to the <console>`.
- Sink with variable (no "the"): `Log <message> to the <console>`.
- Sink with qualified variable: `Log <user: name> to the <console>`.
- Sink with number literal: `Log 42 to the <console>`.
- Sink with boolean variable: `Log <flag> to the <console>`.
- Sink with array literal: `Log [10, 20, 30] to the <console>`.
- Sink with object literal: `Log { status: "ok", version: 1 } to the <console>`.
