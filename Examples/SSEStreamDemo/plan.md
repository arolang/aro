# Build an SSE stream demo for live Wikipedia edits

Create a single-file ARO application that connects to the Wikimedia RecentChanges SSE stream and displays live edits.

In `main.aro`:

1. `Application-Start: SSE Stream Demo` -- Use `Stream the <wiki-change> from "https://stream.wikimedia.org/v2/stream/recentchange"` to subscribe. Use Keepalive.

2. `Application-End: Success` -- Log "Stream closed. Goodbye!".

3. `Process Change: wiki-change Handler` -- Extract title, wiki, and user from the event. Log "Edit on ${wiki}: ${title} by ${user}".
