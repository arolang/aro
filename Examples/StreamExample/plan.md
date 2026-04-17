# Build a file streaming demo with O(1) memory

Create a single-file ARO application that demonstrates the `Stream` action for reading files line by line without loading the entire file into memory.

In the `Application-Start` feature set, use `Stream the <lines> from "./sample.txt"` to open the file as a stream. Iterate with `for each <line> in <lines>` and log each line. This approach uses constant memory regardless of file size, unlike the eager `Read` + `Split` pattern.
