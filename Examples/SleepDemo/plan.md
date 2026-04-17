# Build a Sleep action demo

Create a single-file ARO application that demonstrates the non-blocking Sleep action with different duration formats.

In the `Application-Start` feature set:

1. Sleep with literal duration: `Sleep the <short-pause> for 1 second`. Log the slept value with `<short-pause: slept>`.
2. Sleep with variable duration: Create `<wait-time>` with 2, then `Sleep the <long-pause> for <wait-time> seconds`.
3. Sleep with milliseconds: `Sleep the <brief> for 500 milliseconds`.

Log before and after each sleep to show the timing.
