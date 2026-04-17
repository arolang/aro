# Build a Receive action demo with domain events

Create a single-file ARO application that demonstrates the `Receive` action for getting event payloads.

In `main.aro`:

1. `Application-Start: Receive Data Demo` -- Create a message "Hello from event system!", emit a `<MessageReceived: event>` with the message, and return OK.

2. `Process Message: MessageReceived Handler` -- Use `Receive the <payload> from the <event>` to get the event payload. Log the received payload and return OK.
