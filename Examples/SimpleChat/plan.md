# Build a simple chat application with HTTP and WebSocket

Create an ARO application that combines HTTP endpoints for posting messages with a TCP socket server for real-time delivery to connected clients.

The application needs four files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with two endpoints on `/status`: `GET` (operationId: `getStatus`) to retrieve the last posted message, and `POST` (operationId: `postStatus`) to post a new message.

- `main.aro` -- The `Application-Start` feature set. Start the HTTP server, start the socket server on port 9000, use Keepalive, return OK.

- `api.aro` -- Two HTTP handler feature sets:
  - `getStatus` -- Retrieve the last message from `<message-repository: last>` and return it.
  - `postStatus` -- Extract the message from `<body: message>`, store it into `<message-repository>`, broadcast it to all socket clients using `Broadcast the <message> to the <socket-server>`, return Created status.

- `socket.aro` -- Two socket event handlers:
  - `Handle Client Connected` -- Extract client id, send a welcome message explaining they'll receive messages when posted via HTTP.
  - `Handle Client Disconnected` -- Log the disconnection.
