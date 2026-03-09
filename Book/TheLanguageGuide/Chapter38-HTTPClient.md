# Chapter 38: HTTP Client

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

<div style="text-align: center; margin: 2em 0;">
<svg width="420" height="220" viewBox="0 0 420 220" xmlns="http://www.w3.org/2000/svg" font-family="sans-serif">
  <!-- Feature Set (indigo, top) -->
  <rect x="120" y="10" width="180" height="46" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>
  <text x="210" y="30" text-anchor="middle" font-size="11" fill="#4338ca" font-weight="bold">Feature Set</text>
  <text x="210" y="48" text-anchor="middle" font-size="9" fill="#4338ca">Fetch the &lt;response&gt; from &lt;url&gt;</text>

  <!-- Arrow down: HTTP request -->
  <line x1="210" y1="56" x2="210" y2="94" stroke="#1f2937" stroke-width="2"/>
  <polygon points="210,94 205,84 215,84" fill="#1f2937"/>
  <text x="260" y="80" text-anchor="start" font-size="8" fill="#374151">HTTP request</text>

  <!-- External API (amber, dashed) -->
  <rect x="120" y="96" width="180" height="46" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2" stroke-dasharray="4,2"/>
  <text x="210" y="116" text-anchor="middle" font-size="11" fill="#92400e" font-weight="bold">External API</text>
  <text x="210" y="134" text-anchor="middle" font-size="9" fill="#92400e">GET /api/data</text>

  <!-- Arrow up: HTTP response -->
  <line x1="196" y1="96" x2="196" y2="58" stroke="#1f2937" stroke-width="2"/>
  <polygon points="196,58 191,68 201,68" fill="#1f2937"/>
  <text x="80" y="80" text-anchor="end" font-size="8" fill="#374151">HTTP response</text>

  <!-- Arrow down from Feature Set to Extract box -->
  <line x1="210" y1="56" x2="210" y2="56" stroke="none"/>
  <line x1="330" y1="33" x2="380" y2="33" stroke="#6366f1" stroke-width="2"/>
  <line x1="380" y1="33" x2="380" y2="168" stroke="#6366f1" stroke-width="2"/>
  <line x1="380" y1="168" x2="332" y2="168" stroke="#6366f1" stroke-width="2"/>
  <polygon points="332,168 342,163 342,173" fill="#6366f1"/>

  <!-- Extract box (green) -->
  <rect x="120" y="156" width="210" height="46" rx="4" fill="#d1fae5" stroke="#22c55e" stroke-width="2"/>
  <text x="225" y="176" text-anchor="middle" font-size="10" fill="#166534" font-weight="bold">Extract body</text>
  <text x="225" y="194" text-anchor="middle" font-size="8" fill="#166534">Extract &lt;body&gt; from &lt;response: body&gt;</text>
</svg>
</div>

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

*Next: Chapter 39 — Concurrency*
