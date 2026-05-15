# Build a multi-endpoint HTTP server

Create an ARO HTTP server application with three endpoints using the contract-first approach.

The application needs three files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with three paths:
  - `GET /welcome` (operationId: `handleRoot`) -- returns a MessageResponse with a `message` string
  - `GET /health` (operationId: `checkHealth`) -- returns a HealthResponse with a `status` string
  - `POST /echo` (operationId: `echoMessage`) -- accepts an EchoRequest with a `message` string and returns an EchoResponse

- `main.aro` -- The `Application-Start` feature set. Log a startup message, start the HTTP server with an empty config `{}`, log that the server is ready on port 8080, use Keepalive, and return OK.

- `handlers.aro` -- Three feature sets matching the operationIds:
  - `handleRoot` -- Creates a message "Welcome to ARO!" and returns it as JSON `{ message: <message> }`
  - `checkHealth` -- Creates a status "healthy" and returns it as JSON `{ status: <status> }`
  - `echoMessage` -- Extracts the message from `<request: body>`, creates an echo variable with it, and returns `<echo>`
