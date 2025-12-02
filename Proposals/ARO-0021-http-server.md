# ARO-0021: HTTP Server

* Proposal: ARO-0021
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0020, ARO-0012

## Abstract

This proposal defines HTTP server capabilities for ARO applications using SwiftNIO, enabling web service development with event-driven request handling.

## Motivation

Modern applications often expose HTTP APIs. ARO needs:

1. **HTTP Server**: Listen for incoming HTTP requests
2. **Request Routing**: Match requests to feature sets
3. **Event Integration**: Publish HTTP events to the event system
4. **Response Building**: Construct HTTP responses from feature set results

## Proposed Solution

### 1. Server Initialization

Start an HTTP server using the `<Start>` action:

```aro
(Application-Start: HTTP Server) {
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}
```

### 2. HTTP Request Event

When a request arrives, an `HTTPRequestReceivedEvent` is published:

```swift
public struct HTTPRequestReceivedEvent: RuntimeEvent {
    public let requestId: String
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data?
}
```

### 3. Route Feature Sets

Feature sets can be named as route handlers:

```aro
(GET /users: List Users) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(POST /users: Create User) {
    <Extract> the <user-data> from the <request: body>.
    <Validate> the <user-data> for the <user-schema>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(GET /users/{id}: Get User) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Return> an <OK: status> with <user>.
}
```

### 4. Request Handling

Access request data in feature sets:

```aro
<Extract> the <method> from the <request: method>.
<Extract> the <path> from the <request: path>.
<Extract> the <headers> from the <request: headers>.
<Extract> the <body> from the <request: body>.
<Extract> the <query-params> from the <request: query>.
```

### 5. Response Building

Return responses with status and data:

```aro
(* Success responses *)
<Return> an <OK: status> with <data>.
<Return> a <Created: status> with <resource>.
<Return> a <NoContent: status> for the <deletion>.

(* Error responses *)
<Return> a <BadRequest: status> with <validation-errors>.
<Return> a <NotFound: status> for the <missing: resource>.
<Return> a <Forbidden: status> for the <unauthorized: access>.
```

### 6. SwiftNIO Integration

The runtime uses SwiftNIO for HTTP handling:

```swift
public final class AROHTTPServer: HTTPServerService {
    private let group: MultiThreadedEventLoopGroup
    private let eventBus: EventBus

    public func start(port: Int) async throws {
        // Configure SwiftNIO server
        let bootstrap = ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline()
                    .flatMap {
                        channel.pipeline.addHandler(HTTPHandler(eventBus: self.eventBus))
                    }
            }

        let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
        eventBus.publish(HTTPServerStartedEvent(port: port))
    }
}
```

---

## Grammar Extension

```ebnf
(* Route-named feature set *)
route_feature_set = "(" , http_method , route_path , ":" , business_activity , ")" , block ;
http_method = "GET" | "POST" | "PUT" | "DELETE" | "PATCH" ;
route_path = "/" , { path_segment } ;
path_segment = identifier | "{" , identifier , "}" ;
```

---

## Complete Example

```aro
(* HTTP Server Application *)

(Application-Start: REST API) {
    <Log> the <startup: message> for the <console> with "Starting REST API".
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}

(GET /: Root) {
    <Create> the <response> with { message: "Welcome to the API" }.
    <Return> an <OK: status> with <response>.
}

(GET /health: Health Check) {
    <Create> the <status> with { healthy: true }.
    <Return> an <OK: status> with <status>.
}

(GET /users: List Users) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(POST /users: Create User) {
    <Extract> the <data> from the <request: body>.
    <Validate> the <data> for the <user-schema>.
    <Create> the <user> with <data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}
```

---

## Implementation Notes

- HTTP server runs on SwiftNIO's event loop
- Requests are published as events for flexible handling
- Route matching supports path parameters (`{id}`)
- Response status maps to HTTP status codes

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
