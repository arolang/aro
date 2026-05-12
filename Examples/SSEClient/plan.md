# Build an SSE (Server-Sent Events) client

Create a single-file ARO application that subscribes to a Server-Sent Events stream and processes incoming events.

In `main.aro`:

1. `Application-Start: SSE Client Demo` -- Create an SSE URL (e.g., Wikimedia RecentChanges stream). Use `Stream the <wiki-update> from <sse-url> with { retry: 5.0 }` to subscribe with auto-reconnect. Use Keepalive to stay running.

2. `Application-End: Success` -- Log disconnection message.

3. `Handle Update: wiki-update Handler` -- Extract title and wiki from the event, log the update.
