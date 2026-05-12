# Build an API demonstrating OpenAPI parameter references

Create an ARO application that demonstrates `$ref` in OpenAPI parameters using `components/parameters`.

- `openapi.yaml` -- Define an API on `http://localhost:8087` with two GET endpoints: `/greet` (operationId: `greet`) and `/farewell` (operationId: `farewell`). Both paths use `$ref: '#/components/parameters/Name'` for a shared `name` query parameter. The greet endpoint also references a `Lang` parameter. Define both parameters in `components/parameters`.

- `main.aro` -- `Application-Start` starts the HTTP server, uses Keepalive. Two handler feature sets: `greet` returns `{ message: "Hello, World!" }` and `farewell` returns `{ message: "Goodbye, World!" }`.
