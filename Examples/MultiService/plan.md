# Build a multi-service application with HTTP, sockets, and file monitoring

Create an ARO application that runs three services simultaneously: an HTTP server, a TCP socket server, and a file monitor, all communicating through the EventBus.

The application needs five files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with two endpoints: `GET /status` (operationId: `getStatus`) returning service statuses, and `POST /broadcast` (operationId: `broadcastMessage`) accepting a message string to broadcast to socket clients.

- `main.aro` -- The `Application-Start` feature set. Create a watched directory using `Make the <directory> to the <path: "watched-dir">`. Start the HTTP server with `{}`, start the socket server with `{ port: 9000 }`, start the file monitor with "watched-dir". Log helpful instructions for testing each service. Use Keepalive and return OK.

- `api.aro` -- Two HTTP handler feature sets. `getStatus` returns an object with status of all three services. `broadcastMessage` extracts the message from the request body and uses `Broadcast the <message> to the <socket>` to send it to all socket clients.

- `socket.aro` -- Three socket event handler feature sets. `Handle Client Connected` extracts the client id, sends a welcome message using `Send the <welcome> to the <client-id>`. `Handle Data Received` extracts the message and echoes it back. `Handle Client Disconnected` logs the disconnection.

- `files.aro` -- Three file event handler feature sets for created, modified, and deleted events. Each extracts the path from the event, logs it, and broadcasts a notification to socket clients using `Broadcast the <notification> to the <socket>`, creating cross-service integration.
