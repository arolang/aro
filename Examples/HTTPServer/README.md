# HTTPServer

A contract-first HTTP server with multiple endpoints defined in OpenAPI.

## What It Does

Starts an HTTP server on port 8080 with routes defined in `openapi.yaml`. Provides welcome, health check, and echo endpoints. Feature sets are named after OpenAPI `operationId` values.

## Features Tested

- **Contract-first API** - Routes defined in `openapi.yaml`
- **OpenAPI integration** - `operationId` maps to feature set names
- **HTTP server** - `<Start>` with `http-server for contract`
- **Request body extraction** - `<Extract>` from `request: body`
- **JSON responses** - Object literal syntax for response data
- **Multi-file application** - `main.aro` and `handlers.aro`
- **Keepalive** - Long-running server with event loop

## Related Proposals

- [ARO-0027: Contract-First APIs](../../Proposals/ARO-0027-contract-first-api.md)
- [ARO-0022: HTTP Server](../../Proposals/ARO-0022-http-server.md)
- [ARO-0028: Long-Running Applications](../../Proposals/ARO-0028-keepalive.md)

## Usage

```bash
# Start the server
aro run ./Examples/HTTPServer

# Test the endpoints
curl http://localhost:8080/welcome
curl http://localhost:8080/health
curl -X POST http://localhost:8080/echo \
  -H "Content-Type: application/json" \
  -d '{"message": "Hello!"}'
```

## Project Structure

```
HTTPServer/
├── main.aro        # Application-Start, server startup
├── handlers.aro    # Feature sets for each operationId
└── openapi.yaml    # API contract (source of truth)
```

## Example Output

```json
// GET /welcome
{"message": "Welcome to ARO!"}

// GET /health
{"status": "healthy"}

// POST /echo
{"echo": {"message": "Hello!"}}
```

---

*The contract comes first. Write the API you want, then implement the handlers that deliver it.*
