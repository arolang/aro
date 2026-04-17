# Build a SHA256 hash verification test

Create a single-file ARO application that tests the built-in hash computation. Compute `<hash1: hash>` from "hello", compute a password hash from "mySecretPassword123", and compute a second hash of "hello" to verify deterministic output (same input produces same hash). Log all results.
