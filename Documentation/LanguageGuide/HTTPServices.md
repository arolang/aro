# HTTP Services

ARO provides built-in HTTP server and client capabilities. This chapter covers how to build web APIs and make HTTP requests.

## HTTP Server

### Starting the Server

Start an HTTP server in Application-Start:

```aro
(Application-Start: Web API) {
    <Start> the <http-server> on port 8080.
    <Return> an <OK: status> for the <startup>.
}
```

### Route Handlers

Define routes using HTTP method prefixes:

```aro
(GET /users: User API) {
    <Retrieve> the <users> from the <user-repository>.
    <Return> an <OK: status> with <users>.
}

(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.
    <Create> the <user> with <user-data>.
    <Store> the <user> into the <user-repository>.
    <Return> a <Created: status> with <user>.
}

(PUT /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <updated-user> from the <user> with <updates>.
    <Store> the <updated-user> into the <user-repository>.
    <Return> an <OK: status> with <updated-user>.
}

(DELETE /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Delete> the <user> from the <user-repository> where id = <user-id>.
    <Return> a <NoContent: status> for the <deletion>.
}

(PATCH /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Extract> the <partial-update> from the <request: body>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.
    <Transform> the <patched-user> from the <user> with <partial-update>.
    <Store> the <patched-user> into the <user-repository>.
    <Return> an <OK: status> with <patched-user>.
}
```

### Path Parameters

Use `{param}` for dynamic path segments:

```aro
(GET /users/{userId}: User API) {
    <Extract> the <user-id> from the <request: parameters userId>.
    ...
}

(GET /users/{userId}/orders/{orderId}: Order API) {
    <Extract> the <user-id> from the <request: parameters userId>.
    <Extract> the <order-id> from the <request: parameters orderId>.
    ...
}
```

### Request Data

Access request data using qualified variables:

```aro
(POST /users: User API) {
    (* Path parameters *)
    <Extract> the <id> from the <request: parameters id>.

    (* Query string *)
    <Extract> the <page> from the <request: query page>.
    <Extract> the <limit> from the <request: query limit>.

    (* Request body *)
    <Extract> the <data> from the <request: body>.

    (* Headers *)
    <Extract> the <auth-token> from the <request: headers Authorization>.
    <Extract> the <content-type> from the <request: headers Content-Type>.

    (* Method and path *)
    <Extract> the <method> from the <request: method>.
    <Extract> the <path> from the <request: path>.

    ...
}
```

### Response Status Codes

Return appropriate status codes:

```aro
(* 2xx Success *)
<Return> an <OK: status> with <data>.           (* 200 *)
<Return> a <Created: status> with <resource>.   (* 201 *)
<Return> an <Accepted: status> for <async>.     (* 202 *)
<Return> a <NoContent: status> for <deletion>.  (* 204 *)

(* 4xx Client Errors *)
<Return> a <BadRequest: status> with <errors>.       (* 400 *)
<Return> an <Unauthorized: status> for <auth>.       (* 401 *)
<Return> a <Forbidden: status> for <access>.         (* 403 *)
<Return> a <NotFound: status> for <missing>.         (* 404 *)
<Return> a <Conflict: status> for <duplicate>.       (* 409 *)
<Return> an <UnprocessableEntity: status> for <validation>. (* 422 *)

(* 5xx Server Errors *)
<Return> an <InternalError: status> for <error>.     (* 500 *)
<Return> a <ServiceUnavailable: status> for <down>.  (* 503 *)
```

### Response Headers

Set custom response headers:

```aro
(GET /download/{id}: Download API) {
    <Retrieve> the <file> from the <file-repository> where id = <id>.

    <Set> the <response: headers Content-Disposition> to "attachment; filename=${file.name}".
    <Set> the <response: headers Content-Type> to <file: mimeType>.

    <Return> an <OK: status> with <file: content>.
}
```

## RESTful Patterns

### Collection Resource

```aro
(* List all *)
(GET /products: Product API) {
    <Extract> the <page> from the <request: query page>.
    <Extract> the <limit> from the <request: query limit>.

    <Retrieve> the <products> from the <product-repository>
        with pagination <page> <limit>.

    <Return> an <OK: status> with <products>.
}

(* Create new *)
(POST /products: Product API) {
    <Extract> the <product-data> from the <request: body>.
    <Validate> the <product-data> for the <product-schema>.
    <Create> the <product> with <product-data>.
    <Store> the <product> into the <product-repository>.
    <Return> a <Created: status> with <product>.
}
```

### Single Resource

```aro
(* Get one *)
(GET /products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.

    if <product> is empty then {
        <Return> a <NotFound: status> for the <missing: product>.
    }

    <Return> an <OK: status> with <product>.
}

(* Update one *)
(PUT /products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Extract> the <updates> from the <request: body>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.

    if <product> is empty then {
        <Return> a <NotFound: status> for the <missing: product>.
    }

    <Transform> the <updated> from the <product> with <updates>.
    <Store> the <updated> into the <product-repository>.
    <Return> an <OK: status> with <updated>.
}

(* Delete one *)
(DELETE /products/{id}: Product API) {
    <Extract> the <product-id> from the <request: parameters>.
    <Retrieve> the <product> from the <product-repository> where id = <product-id>.

    if <product> is empty then {
        <Return> a <NotFound: status> for the <missing: product>.
    }

    <Delete> the <product> from the <product-repository> where id = <product-id>.
    <Return> a <NoContent: status> for the <deletion>.
}
```

### Nested Resources

```aro
(* User's orders *)
(GET /users/{userId}/orders: Order API) {
    <Extract> the <user-id> from the <request: parameters>.
    <Retrieve> the <orders> from the <order-repository> where userId = <user-id>.
    <Return> an <OK: status> with <orders>.
}

(* Specific order for user *)
(GET /users/{userId}/orders/{orderId}: Order API) {
    <Extract> the <user-id> from the <request: parameters userId>.
    <Extract> the <order-id> from the <request: parameters orderId>.
    <Retrieve> the <order> from the <order-repository>
        where id = <order-id> and userId = <user-id>.

    if <order> is empty then {
        <Return> a <NotFound: status> for the <missing: order>.
    }

    <Return> an <OK: status> with <order>.
}
```

## HTTP Client

### Making Requests

Make outgoing HTTP requests:

```aro
(* Simple GET *)
<Fetch> the <data> from "https://api.example.com/resource".

(* GET with response handling *)
<Fetch> the <response> from "https://api.example.com/users".
<Extract> the <users> from the <response: body>.
```

### API Definitions

Define external APIs:

```aro
api WeatherAPI {
    baseUrl: "https://api.weather.com/v1";
    headers: {
        "API-Key": "${WEATHER_API_KEY}",
        "Accept": "application/json"
    };
}

(Get Weather: External Service) {
    <Extract> the <city> from the <request: query city>.
    <Fetch> the <weather> from <WeatherAPI: GET /forecast?city=${city}>.
    <Return> an <OK: status> with <weather>.
}
```

### Request Methods

```aro
(* GET *)
<Fetch> the <users> from <UserAPI: GET /users>.

(* POST *)
<Call> the <result> via <UserAPI: POST /users> with <user-data>.

(* PUT *)
<Call> the <updated> via <UserAPI: PUT /users/{id}> with <updates>.

(* DELETE *)
<Call> the <result> via <UserAPI: DELETE /users/{id}>.

(* PATCH *)
<Call> the <patched> via <UserAPI: PATCH /users/{id}> with <partial>.
```

### Response Handling

```aro
(Fetch External Data: External Service) {
    <Fetch> the <response> from "https://api.example.com/data".

    <Extract> the <status-code> from the <response: statusCode>.
    <Extract> the <body> from the <response: body>.
    <Extract> the <headers> from the <response: headers>.

    if <status-code> is not 200 then {
        <Log> the <error: message> for the <console> with "API error: ${status-code}".
        <Return> a <BadRequest: status> for the <api: error>.
    }

    <Return> an <OK: status> with <body>.
}
```

### Error Handling

```aro
(Call External API: External Service) {
    <Fetch> the <response> from <ExternalAPI: GET /resource>.

    <Extract> the <status> from the <response: statusCode>.

    if <status> >= 500 then {
        <Return> a <ServiceUnavailable: status> for the <external: error>.
    }

    if <status> is 404 then {
        <Return> a <NotFound: status> for the <missing: resource>.
    }

    if <status> >= 400 then {
        <Extract> the <error> from the <response: body>.
        <Return> a <BadRequest: status> with <error>.
    }

    <Extract> the <data> from the <response: body>.
    <Return> an <OK: status> with <data>.
}
```

## Authentication

### API Key

```aro
(GET /secure: Secure API) {
    <Extract> the <api-key> from the <request: headers X-API-Key>.

    when <api-key> is empty {
        <Return> an <Unauthorized: status> for the <missing: api-key>.
    }

    <Validate> the <api-key> for the <api-key-registry>.

    if <validation> is failed then {
        <Return> an <Unauthorized: status> for the <invalid: api-key>.
    }

    <Retrieve> the <data> from the <repository>.
    <Return> an <OK: status> with <data>.
}
```

### Bearer Token

```aro
(GET /protected: Protected API) {
    <Extract> the <auth-header> from the <request: headers Authorization>.

    when <auth-header> is empty {
        <Return> an <Unauthorized: status> for the <missing: token>.
    }

    <Parse> the <token> from the <auth-header> as "Bearer".
    <Validate> the <token> for the <jwt-validator>.

    if <token> is invalid then {
        <Return> an <Unauthorized: status> for the <invalid: token>.
    }

    <Extract> the <user-id> from the <token: claims userId>.
    <Retrieve> the <user> from the <user-repository> where id = <user-id>.

    <Return> an <OK: status> with <data>.
}
```

## Middleware Patterns

### Request Logging

```aro
(* Log all requests - handler pattern *)
(Log Request: HTTPRequest Handler) {
    <Extract> the <method> from the <request: method>.
    <Extract> the <path> from the <request: path>.
    <Log> the <access: log> for the <console> with "${method} ${path}".
    <Return> an <OK: status> for the <logging>.
}
```

### Rate Limiting

```aro
(Check Rate Limit: HTTPRequest Handler) {
    <Extract> the <client-ip> from the <request: headers X-Forwarded-For>.
    <Retrieve> the <requests> from the <rate-limit-cache> where ip = <client-ip>.

    if <requests: count> > 100 then {
        <Return> a <TooManyRequests: status> for the <rate-limit>.
    }

    <Increment> the <request-count> for the <client-ip>.
    <Return> an <OK: status> for the <rate-check>.
}
```

## Best Practices

### Validate Input

```aro
(POST /users: User API) {
    <Extract> the <user-data> from the <request: body>.

    (* Always validate input *)
    <Validate> the <user-data> for the <user-schema>.

    if <validation> is failed then {
        <Return> a <BadRequest: status> with <validation: errors>.
    }

    <Create> the <user> with <user-data>.
    <Return> a <Created: status> with <user>.
}
```

### Use Appropriate Status Codes

```aro
(* Be specific with status codes *)
<Return> a <Created: status> with <new-resource>.    (* Not just OK *)
<Return> a <NoContent: status> for the <deletion>.   (* Not OK with empty body *)
<Return> a <NotFound: status> for the <missing>.     (* Not BadRequest *)
```

### Handle Errors Gracefully

```aro
(GET /users/{id}: User API) {
    <Extract> the <user-id> from the <request: parameters>.

    (* Handle not found *)
    <Retrieve> the <user> from the <repository> where id = <user-id>.
    if <user> is empty then {
        <Return> a <NotFound: status> for the <missing: user>.
    }

    <Return> an <OK: status> with <user>.
}
```

## Next Steps

- [File System](FileSystem.md) - File operations
- [Sockets](Sockets.md) - TCP communication
- [Events](Events.md) - Event-driven patterns
