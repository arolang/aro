# Build a WebSocket server demo

Create an ARO application demonstrating WebSocket server capabilities with connection lifecycle, echo, and broadcast.

The application needs four files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with `GET /health` (operationId: `healthCheck`) for health status and `GET /ws` (operationId: `websocketEndpoint`) for WebSocket upgrade (returns 101 Switching Protocols).

- `main.aro` -- The `Application-Start` feature set. Start the HTTP server, log the WebSocket endpoint URL (`ws://localhost:8080/ws`), use Keepalive, return OK.

- `api.aro` -- A single `healthCheck` feature set that returns a response with status "healthy" and the WebSocket URL.

- `handlers.aro` -- Three WebSocket event handler feature sets (business activity: `WebSocket Event Handler`):
  - `Handle WebSocket Connect` -- Extract connectionId, path, and remoteAddress from the event. Send a welcome message to the specific connection using `Send the <welcome> to the <websocket-connection: connectionId>`. Broadcast a "new user joined" notification to all connections using `Broadcast the <notification> to the <websocket>`.
  - `Handle WebSocket Message` -- Extract message and connectionId. Echo the message back to the sender with an "Echo: " prefix using `Send`. Also broadcast the message to all clients with a "Broadcast: " prefix.
  - `Handle WebSocket Disconnect` -- Extract connectionId and reason. Broadcast a "user has left" notification to remaining clients.
