# HTTP Client

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

- Uses AsyncHTTPClient for non-blocking requests
- Default timeout: 30 seconds
- Automatically parses JSON responses
- Thread-safe for concurrent requests
- Available on macOS and Linux (not Windows)

## See Also

- [ARO-0022: HTTP Client](https://github.com/KrisSimon/aro/blob/main/Proposals/ARO-0022-http-client.md) - Full specification
- [Examples/HTTPClient](https://github.com/KrisSimon/aro/tree/main/Examples/HTTPClient) - Working example
