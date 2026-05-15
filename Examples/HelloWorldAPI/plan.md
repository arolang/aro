# Build a hello world HTTP API

Create an ARO HTTP API application that serves a single GET endpoint at `/hello` which returns a JSON greeting `{"message": "Hello World"}`.

The application needs three files:

- `openapi.yaml` -- Define the API contract with a single path `/hello` using a GET operation with operationId `sayHello`. The server should listen on `http://localhost:8000`. Define a `HelloResponse` schema with a required `message` string property.

- `main.aro` -- The application entry point. Log a startup message, start the HTTP server with the contract, log a ready message, use Keepalive to keep the application running for events, and return OK. Also include an `Application-End: Success` handler that logs a shutdown message, stops the HTTP server, and returns OK.

- `hello.aro` -- A feature set named `sayHello` (matching the operationId from the OpenAPI contract) with business activity "Hello API". It should create a message variable with "Hello World" and return an OK status with an inline object `{ message: <message> }`.
