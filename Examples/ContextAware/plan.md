# Build a context-aware response formatting demo

Create an ARO application that demonstrates how output formatting adapts to execution context: human-readable for `aro run`, diagnostic for `aro run --debug`, and JSON for HTTP API requests.

The application needs two files:

- `openapi.yaml` -- Define an API on `http://localhost:8080` with `GET /demo` (operationId: `getDemo`) returning a DemoResponse with user, order, tags, and summary fields.

- `main.aro` -- Two feature sets:

  1. `Application-Start: Context-Aware Demo` -- Create a user object (id, name, email, role, active, score), an order object (order-id, customer, items, total, status), and a tags list. Publish all three as `<demo-user>`, `<demo-order>`, `<demo-tags>` for cross-feature-set access. Log user and order data to the console. Start the HTTP server, use Keepalive. Return OK with an inline object containing user, order, tags, and summary.

  2. `getDemo: Context-Aware Demo` -- Access the published variables and return them as a JSON response for the HTTP context.
