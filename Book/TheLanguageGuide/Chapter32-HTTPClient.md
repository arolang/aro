# Chapter 32: HTTP Client

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
Create the <url> with "https://api.example.com/users".
Request the <users> from the <url>.
```

## POST Requests

Use `to` preposition to make POST requests:

```aro
(* POST with data from context *)
Create the <user-data> with { name: "Alice", email: "alice@example.com" }.
Create the <api-url> with "https://api.example.com/users".
Request the <result> to the <api-url> with <user-data>.
```

## Other HTTP Methods

Use `via` preposition with method specifier for PUT, DELETE, PATCH:

```aro
(* PUT request *)
Request the <result> via PUT the <url> with <update-data>.

(* DELETE request *)
Request the <result> via DELETE the <url>.

(* PATCH request *)
Request the <result> via PATCH the <url> with <partial-data>.
```

## Config Object Syntax

For full control over requests, use a config object with the `with { ... }` clause:

```aro
(* POST with custom headers and timeout *)
Request the <response> from the <api-url> with {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": "Bearer token" },
    body: <data>,
    timeout: 60
}.

(* GET with authorization header *)
Request the <protected-data> from the <api-url> with {
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
Create the <api-url> with "https://api.example.com/users".
Request the <response> from the <api-url>.

(* Access response metadata *)
Extract the <status> from the <response: statusCode>.
Extract the <is-ok> from the <response: isSuccess>.

(* Access response body - response IS the parsed body *)
Extract the <first-user> from the <response: 0>.
```

## Complete Example

```aro
(* Fetch weather data from Open-Meteo API *)

(Application-Start: Weather Client) {
    Log "Fetching weather..." to the <console>.

    Create the <api-url> with "https://api.open-meteo.com/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true".
    Request the <weather> from the <api-url>.

    Log <weather> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

## Unified URL I/O (ARO-0052)

ARO provides a unified syntax for reading from and writing to URLs, using the same `Read` and `Write` actions used for files. This creates a seamless I/O model where data sources can be local files or remote endpoints.

### Reading from URLs

Use the `<url: "...">` system object with the `Read` action to perform HTTP GET requests:

```aro
(* Simple GET request *)
Read the <users> from the <url: "https://api.example.com/users">.

(* The response is automatically parsed based on Content-Type *)
Extract the <first-user> from the <users: 0>.
Log <first-user: name> to the <console>.
```

### Writing to URLs

Use the `<url: "...">` system object with the `Write` action to perform HTTP POST requests:

```aro
(* POST request - data is automatically serialized to JSON *)
Create the <user> with { name: "Alice", email: "alice@example.com" }.
Write the <user> to the <url: "https://api.example.com/users">.
```

### Request Options

Both `Read` and `Write` support the `with { ... }` clause for headers, timeout, and other options:

```aro
(* GET with custom headers *)
Read the <data> from the <url: "https://api.example.com/protected"> with {
    headers: {
        Authorization: "Bearer ${token}",
        Accept: "application/json"
    },
    timeout: 60
}.

(* POST with custom headers *)
Write the <payload> to the <url: "https://api.example.com/submit"> with {
    headers: {
        Authorization: "Bearer ${token}",
        X-Request-ID: "${request-id}"
    },
    timeout: 120
}.
```

**Options Reference:**

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `headers` | Map | `{}` | HTTP request headers |
| `timeout` | Integer | `30` | Request timeout in seconds |
| `encoding` | String | `"utf-8"` | Response/request body encoding |

### Automatic Format Detection

When reading from URLs, ARO automatically parses the response based on the `Content-Type` header:

| Content-Type | Parsed As |
|--------------|-----------|
| `application/json` | Dictionary/Array |
| `application/xml`, `text/xml` | Dictionary |
| `text/csv` | Array of rows |
| `text/yaml`, `application/x-yaml` | Dictionary |
| `text/plain` | String |
| `text/html` | String |

### Data Pipeline Example

The unified I/O syntax makes data pipelines simple and readable:

```aro
(Sync Remote Data: Data Pipeline) {
    (* Fetch from remote API *)
    Read the <remote-data> from the <url: "https://api.example.com/export">.

    (* Save to local file *)
    Write the <remote-data> to the <file: "./data/snapshot.json">.

    (* Read local, transform, upload *)
    Read the <local-report> from the <file: "./reports/daily.json">.
    Write the <local-report> to the <url: "https://api.example.com/upload">.

    Return an <OK: status> for the <sync>.
}
```

### When to Use URL I/O vs Request

| Use Case | Action |
|----------|--------|
| Simple GET (data retrieval) | `Read ... from <url: "...">` |
| Simple POST (data submission) | `Write ... to <url: "...">` |
| Full HTTP control (PUT, DELETE, PATCH) | `Request ... via METHOD` |
| Complex request configuration | `Request ... with { method: "...", ... }` |

---

## Implementation Notes

- Uses Foundation's URLSession for HTTP requests
- Compatible with both interpreter (`aro run`) and compiled binaries (`aro build`)
- Default timeout: 30 seconds
- Automatically parses JSON responses
- Thread-safe for concurrent requests
- Available on macOS and Linux (not Windows)

---

*Next: Chapter 33 — Concurrency*
