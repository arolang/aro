# Build a configurable timeout demo

Create a single-file ARO application that demonstrates the `Configure` action for setting runtime configuration values.

In `main.aro`, define two feature sets:

1. `Application-Start: Configurable Timeout Example` -- Create a validation timeout value of 10, then use `Configure the <validation: timeout> with <validation-timeout>` to set it. Log the configured timeout value and return OK.

2. `Validate Binary Path: Custom Validation` -- A separate feature set that extracts a path from the request body and retrieves the configured timeout with `Extract the <timeout> from the <validation: timeout>`. Logs the timeout being used for validation and returns OK.
