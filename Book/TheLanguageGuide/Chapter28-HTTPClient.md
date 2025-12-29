# Chapter 28: HTTP Client

ARO provides HTTP client capabilities for making requests to external services and APIs.

## Making HTTP Requests

Use the `<Request>` action to make HTTP requests. The preposition determines the HTTP method:

- `from` - GET request
- `to` - POST request
- `via METHOD` - Explicit method (PUT, DELETE, PATCH)

## GET Requests

Use `from` preposition to make GET requests:

```aro
(* Simple GET request *)
<Create> the <url> with "https://api.example.com/users".
<Request> the <users> from the <url>.
```

## POST Requests

Use `to` preposition to make POST requests:

```aro
(* POST with data from context *)
<Create> the <user-data> with { name: "Alice", email: "alice@example.com" }.
<Create> the <api-url> with "https://api.example.com/users".
<Request> the <result> to the <api-url> with <user-data>.
```

## Other HTTP Methods

Use `via` preposition with method specifier for PUT, DELETE, PATCH:

```aro
(* PUT request *)
<Request> the <result> via PUT the <url> with <update-data>.

(* DELETE request *)
<Request> the <result> via DELETE the <url>.

(* PATCH request *)
<Request> the <result> via PATCH the <url> with <partial-data>.
```

## Config Object Syntax

For full control over requests, use a config object with the `with { ... }` clause:

```aro
(* POST with custom headers and timeout *)
<Request> the <response> from the <api-url> with {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": "Bearer token" },
    body: <data>,
    timeout: 60
}.

(* GET with authorization header *)
<Request> the <protected-data> from the <api-url> with {
    headers: { "Authorization": "Bearer my-token" }
}.
```

**Config Options:**

| Option | Type | Description |
|--------|------|-------------|
| `method` | String | HTTP method: GET, POST, PUT, DELETE, PATCH |
| `headers` | Map | Custom HTTP headers |
| `body` | String/Map | Request body (auto-serialized to JSON if map) |
| `timeout` | Number | Request timeout in seconds (default: 30) |

The config `method` overrides the preposition-based method detection. This allows you to use `from` (which defaults to GET) while specifying POST in the config.

## Response Handling

The `<Request>` action automatically parses JSON responses. After a request, these variables are available:

| Variable | Description |
|----------|-------------|
| `result` | Parsed response body (JSON as map/list, or string) |
| `result.statusCode` | HTTP status code (e.g., 200, 404) |
| `result.headers` | Response headers as map |
| `result.isSuccess` | Boolean: true if status 200-299 |

```aro
<Create> the <api-url> with "https://api.example.com/users".
<Request> the <response> from the <api-url>.

(* Access response metadata *)
<Extract> the <status> from the <response: statusCode>.
<Extract> the <is-ok> from the <response: isSuccess>.

(* Access response body - response IS the parsed body *)
<Extract> the <first-user> from the <response: 0>.
```

## Complete Example

```aro
(* Fetch weather data from Open-Meteo API *)

(Application-Start: Weather Client) {
    <Log> the <message> for the <console> with "Fetching weather...".

    <Create> the <api-url> with "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true".
    <Request> the <weather> from the <api-url>.

    <Log> the <data: message> for the <console> with <weather>.

    <Return> an <OK: status> for the <startup>.
}
```

## Implementation Notes

- Uses Foundation's URLSession for HTTP requests
- Compatible with both interpreter (`aro run`) and compiled binaries (`aro build`)
- Default timeout: 30 seconds
- Automatically parses JSON responses
- Thread-safe for concurrent requests
- Available on macOS and Linux (not Windows)

---

*Next: Chapter 29 — Concurrency*
