# HTTP Services

ARO provides built-in HTTP server capabilities using a **contract-first** approach. Routes are defined in an OpenAPI specification, and ARO feature sets handle the requests.

## Contract-First HTTP

ARO uses OpenAPI contracts (`openapi.yaml`) to define HTTP routes. The HTTP server automatically starts when an `openapi.yaml` file is present in your application directory.

**Key Principles:**
1. Routes are defined in `openapi.yaml`, not in ARO code
2. Feature set names must match `operationId` values from the contract
3. No HTTP server without a contract (no `openapi.yaml` = no server)

## Application Structure

```
MyAPI/
├── openapi.yaml      # Required: Defines all HTTP routes
├── main.aro          # Application-Start with Keepalive
└── handlers.aro      # Feature sets matching operationIds
```

## Defining Routes (openapi.yaml)

```yaml
openapi: 3.0.3
info:
  title: User API
  version: 1.0.0

paths:
  /users:
    get:
      operationId: listUsers      # Feature set name in ARO
      responses:
        '200':
          description: Success
    post:
      operationId: createUser     # Feature set name in ARO
      responses:
        '201':
          description: Created

  /users/{id}:
    get:
      operationId: getUser        # Feature set name in ARO
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

## Route Handlers

Feature sets must be named after the `operationId` from your OpenAPI contract:

```aro
(* Feature set name = operationId from openapi.yaml *)

(listUsers: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(createUser: User API) {
    <Extract> the <data> from the <request: body>.
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

## Application Entry Point

The HTTP server starts automatically. Use `<Keepalive>` to keep the application running:

```aro
(Application-Start: User API) {
    <Log> the <startup: message> for the <console> with "User API starting...".
    <Keepalive> the <application> for the <events>.
    <Return> an <OK: status> for the <startup>.
}
```

## Request Data Access

### Path Parameters

```aro
<Extract> the <user-id> from the <pathParameters: id>.
```

### Query Parameters

```aro
<Extract> the <page> from the <queryParameters: page>.
```

### Request Body

```aro
<Extract> the <data> from the <request: body>.
```

### Request Headers

```aro
<Extract> the <auth-token> from the <request: headers Authorization>.
```

## Response Status Codes

```aro
(* 2xx Success *)
<Return> an <OK: status> with <data>.           (* 200 *)
<Return> a <Created: status> with <resource>.   (* 201 *)
<Return> a <NoContent: status> for <deletion>.  (* 204 *)

(* 4xx Client Errors *)
<Return> a <BadRequest: status> with <errors>.       (* 400 *)
<Return> an <Unauthorized: status> for <auth>.       (* 401 *)
<Return> a <Forbidden: status> for <access>.         (* 403 *)
<Return> a <NotFound: status> for <missing>.         (* 404 *)

(* 5xx Server Errors *)
<Return> an <InternalError: status> for <error>.     (* 500 *)
```

## HTTP Client

For making outgoing HTTP requests:

```aro
<Fetch> the <data> from "https://api.example.com/resource".
```

## Next Steps

- [File System](filesystem.html) - File operations and monitoring
- [Sockets](sockets.html) - TCP communication
- [Events](events.html) - Event-driven patterns
