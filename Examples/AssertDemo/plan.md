# Build a string utilities library with Given/When/Then tests

Create a single-file ARO application that defines production feature sets and colocated test feature sets.

In `main.aro`:

1. `Application-Start: String Utils Demo` -- Log a message about running tests and return OK.

2. Three production feature sets (business activity: `String Utils`):
   - `get-length` -- Compute `<len: length>` from `<text>` and return it.
   - `make-uppercase` -- Compute `<upper: uppercase>` from `<text>` and return it.
   - `make-lowercase` -- Compute `<lower: lowercase>` from `<text>` and return it.

3. Six test feature sets (business activity: `String Utils Test`):
   - `length-of-hello` -- Given text "hello", When len from get-length, Then len is 5.
   - `length-of-blank` -- Given text "", Then len is 0.
   - `uppercase-simple` -- Given "hello", Then upper is "HELLO".
   - `uppercase-mixed` -- Given "Hello World", Then upper is "HELLO WORLD".
   - `lowercase-simple` -- Given "HELLO", Then lower is "hello".
   - `lowercase-mixed` -- Given "Hello World", Then lower is "hello world".

Run tests with `aro test ./Examples/AssertDemo`.
