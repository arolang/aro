# Build a zip compression demo using a plugin

Create a single-file ARO application that uses a zip plugin to compress files.

In `main.aro`, the `Application-Start` feature set calls the zip plugin using `Call the <result> from the <zip: compress> with { files: [...], output: "archive.zip" }`, passing a list of file paths and an output path. Log the result. Include an `Application-End: Success` handler that logs completion.
