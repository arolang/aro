# Start with ARO

This guide will walk you through creating your first ARO application: a simple "Hello World" API server.

---

## What is ARO?

ARO (Action-Result-Object) is a domain-specific language for building business applications. It uses natural language-like syntax to express business logic as a series of actions.

**Key concepts:**
- **Contract-First**: Your API is defined in an `openapi.yaml` file before any code
- **Feature Sets**: Business logic is organized into named feature sets
- **Event-Driven**: Feature sets are triggered by events (HTTP requests, custom events, etc.)
- **Natural Syntax**: Code reads like English: `<Action> the <Result> for the <Object>`

---

## Project Structure

An ARO application is a directory containing `.aro` files and an `openapi.yaml` contract:

```
HelloWorldAPI/
├── openapi.yaml      ← API contract (required for HTTP)
├── main.aro          ← Application entry point
└── hello.aro         ← Request handler
```

---

## Step 1: The OpenAPI Contract

Every ARO HTTP application starts with an `openapi.yaml` file. This is your **contract** - it defines what endpoints your API has.

**openapi.yaml:**
```yaml
openapi: 3.0.3
info:
  title: Hello World API
  description: A simple API that returns "Hello World"
  version: 1.0.0

servers:
  - url: http://localhost:8000
    description: Local development server

paths:
  /hello:
    get:
      operationId: sayHello       # ← This name maps to an ARO feature set
      summary: Say Hello
      description: Returns a friendly "Hello World" greeting
      responses:
        '200':
          description: Successful response with greeting
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/HelloResponse'

components:
  schemas:
    HelloResponse:
      type: object
      properties:
        message:
          type: string
          example: Hello World
      required:
        - message
```

**Key Point:** The `operationId: sayHello` is crucial. ARO uses this to route requests to the correct feature set.

---

## Step 2: Application Entry Point

Every ARO application needs exactly ONE `Application-Start` feature set. This is where your application begins.

**main.aro:**
```aro
(* Application Entry Point *)

(Application-Start: Hello World API) {
    (* Log a startup message *)
    <Log> the <startup: message> for the <console> with "Hello World API starting...".

    (* Start the HTTP server on port 8000 *)
    <Start> the <http-server> on <port> with 8000.

    (* Log ready message *)
    <Log> the <ready: message> for the <console> with "Server running at http://localhost:8000".

    (* Keep the application running to process HTTP requests *)
    <Keepalive> the <application> for the <events>.

    (* Return OK to indicate successful startup *)
    <Return> an <OK: status> for the <startup>.
}

(* Optional: Handle graceful shutdown *)
(Application-End: Success) {
    <Log> the <shutdown: message> for the <console> with "Shutting down...".
    <Stop> the <http-server> for the <application>.
    <Return> an <OK: status> for the <shutdown>.
}
```

### Understanding the Syntax

| Element | Meaning |
|---------|---------|
| `(* ... *)` | Comment |
| `(Name: Activity) { }` | Feature set definition |
| `<Action>` | The verb (what to do) |
| `<result: qualifier>` | The result with optional qualifier |
| `for the <object>` | The target of the action |
| `with "value"` | Additional data |

---

## Step 3: Request Handler

The request handler is a feature set whose name **matches** the `operationId` from your OpenAPI contract.

**hello.aro:**
```aro
(* Request Handler for GET /hello *)

(sayHello: Hello API) {
    (* Create the greeting message *)
    <Create> the <greeting> with "Hello World".

    (* Return an OK response with the greeting *)
    <Return> an <OK: status> with <greeting>.
}
```

**Important:** The feature set name `sayHello` must exactly match the `operationId` in your OpenAPI contract. This is how ARO knows which code handles which endpoint.

---

## Running Your Application

### Development Mode (Interpreted)

Run your application directly without compilation:

```bash
# From the project root
aro run ./Examples/HelloWorldAPI
```

You should see:
```
Hello World API starting...
Server running at http://localhost:8000
```

### Testing Your API

Open a new terminal and test with curl:

```bash
curl http://localhost:8000/hello
```

Expected response:
```json
{"message": "Hello World"}
```

---

## Compiling Your Application

ARO can compile your application to a native binary for production deployment.

### Check Syntax First

```bash
aro check ./Examples/HelloWorldAPI
```

This validates all `.aro` files without running them.

### Compile to Binary

```bash
aro compile ./Examples/HelloWorldAPI
```

This produces a compiled report showing the structure of your application.

### Build Native Binary

```bash
aro build ./Examples/HelloWorldAPI
```

This creates a native executable in your application directory.

---

## How It All Works Together

```
┌─────────────────┐
│  openapi.yaml   │  ← Defines: GET /hello → operationId: sayHello
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    ARO Runtime  │  ← Loads contract, starts HTTP server
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  HTTP Request   │  ← GET /hello
│  arrives        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ Route Registry  │  ← Matches /hello → sayHello
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   sayHello      │  ← Feature set executes
│   Feature Set   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  HTTP Response  │  ← {"message": "Hello World"}
└─────────────────┘
```

---

## Key Concepts Summary

| Concept | Description |
|---------|-------------|
| **Contract-First** | Define your API in `openapi.yaml` before writing code |
| **operationId** | Links HTTP endpoints to ARO feature sets |
| **Application-Start** | Required entry point; exactly one per application |
| **Feature Set** | Named block of business logic |
| **Action Statements** | `<Action> the <Result> for the <Object>` |

---

## Common ARO Actions

| Action | Role | Example |
|--------|------|---------|
| `<Extract>` | Request | Get data from request/context |
| `<Create>` | Own | Create new data |
| `<Compute>` | Own | Calculate/transform data |
| `<Validate>` | Own | Check data validity |
| `<Store>` | Export | Save to repository |
| `<Return>` | Response | Send response |
| `<Log>` | Export | Write to console/log |
| `<Start>` | Export | Start a service |
| `<Stop>` | Export | Stop a service |

---

## Next Steps

1. **Add more endpoints**: Define new paths in `openapi.yaml` with unique `operationId` values, then create matching feature sets

2. **Accept parameters**: Use path parameters (`/users/{id}`) and access them via `<Extract> the <id> from the <pathParameters: id>`

3. **Handle request bodies**: For POST/PUT endpoints, use `<Extract> the <data> from the <request: body>`

4. **Add validation**: Use `<Validate>` actions to check input data

5. **Connect to storage**: Use `<Store>` and `<Retrieve>` with repositories

---

## Troubleshooting

### "No openapi.yaml found"
Make sure your application directory contains an `openapi.yaml` file. Without it, the HTTP server won't start.

### "Missing ARO feature set handlers"
Your `operationId` values don't match any feature set names. Ensure each `operationId` in your contract has a matching feature set.

### Server not responding
Check that the port (8000) is not already in use by another application.

---

## Complete Example Files

The complete Hello World API example is available at:
```
Examples/HelloWorldAPI/
├── openapi.yaml
├── main.aro
└── hello.aro
```

Run it with:
```bash
aro run ./Examples/HelloWorldAPI
```
