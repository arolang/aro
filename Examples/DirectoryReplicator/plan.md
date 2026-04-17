# Build a directory structure replicator

Create a single-file ARO application that reads a template directory structure and replicates it in the current location.

In the `Application-Start` feature set:

1. Define the template source path ("./template").
2. Use `List the <all-entries: recursively> from the <directory: template-path>` to recursively list all entries.
3. Iterate with a filtered for-each: `for each <entry> in <all-entries> where <entry: isDirectory> is true`.
4. For each directory entry, extract the full path, split it by the regex `/template\//` to remove the prefix, extract the relative path using `<relative-path: last>` from the split result (ARO-0038 list element access).
5. Create the directory with `Make the <created> to the <path: relative-path>`.

Log each created directory and return OK.
