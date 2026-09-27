# Build a CLI that takes its argument positionally

Create an ARO application invoked as `./crawler https://example.com 3` rather
than `./crawler --url https://example.com --depth 3`.

- `main.aro` — one `Application-Start` feature set whose header declares two
  positional arguments with `takes <url> <depth>`. Read each one through
  `<parameter: …>` and log it. Then read the whole positional list through
  `<parameter: arguments>`, compute its length, and log that.

The point of the example is that a declared positional is read with exactly
the same statement as a flag, so a program does not have to care which spelling
its caller used.
