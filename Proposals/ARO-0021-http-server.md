# ARO-0021: HTTP Server

* Proposal: ARO-0021
* Author: ARO Language Team
* Status: **Implemented**
* Requires: ARO-0020, ARO-0027

## Abstract

This proposal defines HTTP server capabilities for ARO applications using SwiftNIO. The HTTP server is **contract-first**: it automatically starts when an `openapi.yaml` file is present, and routes are defined by the OpenAPI specification.

## Motivation

Modern applications often expose HTTP APIs. ARO needs:

1. **Contract-First Design**: API defined in OpenAPI before implementation
2. **Automatic Server**: No explicit start action required
3. **Event Integration**: Publish HTTP events to the event system
4. **Response Building**: Construct HTTP responses from feature set results

---

## Core Principle

**No `<Start>` action for HTTP server.** The server automatically becomes active when:
1. An `openapi.yaml` (or `.yml`/`.json`) file exists in the application directory
2. At least one route is defined in the OpenAPI document
3. Feature sets with matching `operationId` names exist

---

## 1. OpenAPI Contract

Routes are defined in `openapi.yaml`, not in ARO code:

```yaml
# openapi.yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers
      summary: List all users
      responses:
        '200':
          description: Success
    post:
      operationId: createUser
      summary: Create a user
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateUserRequest'
      responses:
        '201':
          description: Created

  /users/{id}:
    get:
      operationId: getUser
      summary: Get user by ID
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Success
```

---

## 2. Feature Set Naming

Feature sets **must be named after the `operationId`**, not the HTTP path:

```aro
(* Feature set name = operationId from openapi.yaml *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data> for the <user-schema>.
    <Create> the <user> with <data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(getUser: User API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <user> from the <user-repository> where id = <id>.
    <Return> an <OK: status> with <user>.
}
```

---

## 3. Application Entry Point

The HTTP server starts automatically. The `Application-Start` feature set only needs to:
1. Log startup messages (optional)
2. Wait for shutdown signal

```aro
(Application-Start: User API) {
    <Log> the <startup: message> for the <console> with "User API starting...".

    (* HTTP server starts automatically from openapi.yaml *)
    (* No <Start> action needed *)

    <Wait> for <shutdown-signal>.

    <Return> an <OK: status> for the <startup>.
}
```

---

## 4. Request Data Access

Access request data via special context variables:

| Variable | Description |
|----------|-------------|
| `pathParameters` | Path parameters from URL (e.g., `/users/{id}`) |
| `pathParameters.{name}` | Individual path parameter |
| `queryParameters` | Query string parameters |
| `request.body` | Parsed request body (JSON) |
| `request.headers` | Request headers |

```aro
(getUser: User API) {
    (* Path parameter from /users/{id} *)
    <Extract> the <user-id> from the <pathParameters: id>.

    (* Query parameters *)
    <Extract> the <include-details> from the <queryParameters: details>.

    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}

(createUser: User API) {
    (* Request body parsed as JSON *)
    <Extract> the <data> from the <request: body>.
    <Extract> the <name> from the <data: name>.
    <Extract> the <email> from the <data: email>.

    <Create> the <user> with <data>.
    <Return> a <Created: status> with <user>.
}
```

---

## 5. Response Building

Return responses with status codes:

```aro
(* Success responses *)
<Return> an <OK: status> with <data>.           (* 200 *)
<Return> a <Created: status> with <resource>.   (* 201 *)
<Return> a <NoContent: status> for the <action>.(* 204 *)

(* Error responses *)
<Return> a <BadRequest: status> with <errors>.  (* 400 *)
<Return> a <NotFound: status> for the <resource>.(* 404 *)
<Return> a <Forbidden: status> for the <access>.(* 403 *)
```

---

## 6. Server Behavior

### Without OpenAPI Contract

```
$ aro run ./MyApp
No openapi.yaml found - HTTP server disabled
Application running (no HTTP routes available)
```

### With OpenAPI Contract

```
$ aro run ./MyApp
Loading openapi.yaml...
Validating contract against feature sets...
  ✓ listUsers -> GET /users
  ✓ createUser -> POST /users
  ✓ getUser -> GET /users/{id}
HTTP Server started on port 8080
```

### Missing Feature Sets

```
Error: Missing ARO feature set handlers for the following operations:
  - GET /users requires feature set named 'listUsers'
  - POST /users requires feature set named 'createUser'

Create feature sets with names matching the operationIds in your OpenAPI contract.
```

---

## 7. Complete Example

### openapi.yaml

```yaml
openapi: 3.0.3
info:
  title: Hello World API
  version: 1.0.0

paths:
  /hello:
    get:
      operationId: sayHello
      responses:
        '200':
          description: Success
```

### main.aro

```aro
(Application-Start: Hello World API) {
    <Log> the <startup: message> for the <console> with "Hello World API starting...".
    <Wait> for <shutdown-signal>.
    <Return> an <OK: status> for the <startup>.
}

(sayHello: Hello API) {
    <Create> the <greeting> with "Hello, World!".
    <Return> an <OK: status> with <greeting>.
}
```

---

## Implementation Location

The HTTP server is implemented in:

- `Sources/ARORuntime/HTTP/HTTPServer.swift` - SwiftNIO-based HTTP server
- `Sources/ARORuntime/OpenAPI/OpenAPIHTTPHandler.swift` - Route matching via OpenAPI
- `Sources/ARORuntime/OpenAPI/OpenAPIRouteRegistry.swift` - Path pattern matching
- `Sources/ARORuntime/OpenAPI/OpenAPILoader.swift` - Contract loading
- `Sources/ARORuntime/Application/ApplicationLoader.swift` - Auto-start logic

Examples:
- `Examples/HelloWorldAPI/` - Simple HTTP API
- `Examples/UserService/` - Full CRUD API

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
| 2.0 | 2024-12 | Contract-first approach: removed `<Start>`, feature sets named after operationId |
