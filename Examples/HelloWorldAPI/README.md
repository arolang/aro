# HelloWorldAPI

The simplest HTTP API - a single endpoint that returns "Hello World".

## What It Does

Starts an HTTP server with one endpoint (`GET /hello`) defined in OpenAPI. Demonstrates the minimal setup for a contract-first web service with proper application lifecycle handling.

## Features Tested

- **Contract-first HTTP** - Route from `openapi.yaml`, handler from `.aro`
- **OpenAPI operationId** - `sayHello` maps to feature set name
- **HTTP server lifecycle** - Start, keepalive, and graceful shutdown
- **Application-End** - `<Stop>` action for clean server shutdown
- **JSON response** - Object literal for structured response

## Related Proposals

- [ARO-0027: Contract-First APIs](../../Proposals/ARO-0027-contract-first-api.md)
- [ARO-0022: HTTP Server](../../Proposals/ARO-0022-http-server.md)
- [ARO-0028: Long-Running Applications](../../Proposals/ARO-0028-keepalive.md)

## Usage

```bash
# Start the server
aro run ./Examples/HelloWorldAPI

# Test the endpoint
curl http://localhost:8000/hello
```

## Project Structure

```
HelloWorldAPI/
├── main.aro        # Application-Start and Application-End
├── hello.aro       # sayHello feature set (handler)
└── openapi.yaml    # API contract with /hello endpoint
```

## Example Output

```json
{"message": "Hello World"}
```

---

*From contract to running server in three files. This is what "convention over configuration" looks like when the convention is an industry standard.*
