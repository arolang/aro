# Build a file existence checking demo

Create a single-file ARO application that demonstrates the `Exists` action for checking file and directory existence.

In the `Application-Start` feature set, check four paths:

1. Check if an existing file exists: `Exists the <file-exists> for the <file: filepath>` with a path to main.aro.
2. Check if an existing directory exists: `Exists the <dir-exists> for the <directory: dirpath>`.
3. Check for a non-existent file: should return false.
4. Check for a non-existent directory: should return false.

Log each result and return OK.
