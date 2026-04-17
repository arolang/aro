# Build a stateful external service demo

Create an ARO application that demonstrates the `Call` action for invoking external services that maintain state across calls.

In `main.aro`, the `Application-Start` feature set should:

1. Call a counter service's increment operation: `Call the <first-increment-response> from the <counter: increment> with {}`. Extract the count from the response.

2. Call increment again to show state persists across calls (count goes from 1 to 2).

3. Call the counter's get operation: `Call the <current-count-response> from the <counter: get> with {}`. Extract and log the final count.

4. Log a summary showing the state progression: 0 -> 1 -> 2.

Include an `Application-End: Success` handler that logs a completion message.
