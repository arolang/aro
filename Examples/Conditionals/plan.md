# Build a conditional branching demo

Create a single-file ARO application that demonstrates guarded statements and match expressions.

In the `Application-Start` feature set:

1. Create test variables: `<method>` set to "POST", `<user-role>` set to "admin", and `<status-code>` set to 200.

2. Use a `when` guard on a Log statement to conditionally log "Admin access detected!" only when `<user-role>` equals "admin".

3. Use a `match` expression on `<method>` with cases for "GET", "POST", "PUT", "DELETE", and an `otherwise` fallback. Each case logs which HTTP method is being handled.

4. Use a second `match` expression on `<status-code>` with cases for 200 ("Request successful"), 404 ("Resource not found"), 500 ("Server error"), and an `otherwise` fallback.

Return OK at the end.
