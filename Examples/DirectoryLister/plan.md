# Build a cross-platform directory listing demo

Create a single-file ARO application that lists directory contents using the native `List` action (no shell commands needed).

In the `Application-Start` feature set, create a path to a test-data directory, use `List the <entries> from the <directory: path>` to get the directory listing, then iterate over entries with a for-each loop logging each `<entry: name>`. Return OK.
