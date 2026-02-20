# ARO-0052: Unified URL I/O

* Proposal: ARO-0052
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0008, ARO-0040

## Abstract

This proposal extends the Read and Write actions to support URLs alongside file paths. Reading from a URL performs an HTTP GET request, while writing to a URL performs an HTTP POST request. This creates a unified I/O model where data sources and sinks can be either local files or remote endpoints.

---

## 1. Motivation

### 1.1 Current State

Currently, ARO separates file I/O and HTTP operations:

```aro
(* File I/O uses Read/Write *)
Read the <data> from the <file: "./data.json">.
Write the <result> to the <file: "./output.json">.

(* HTTP requires Fetch/Call actions *)
Fetch the <response> from the <endpoint: "https://api.example.com/data">.
Call the <result> from the <api: "https://api.example.com/submit"> with <payload>.
```

### 1.2 Unified Vision

Data is data, regardless of location. Reading from a URL should be as natural as reading from a file:

```aro
(* Local file *)
Read the <config> from the <file: "./config.json">.

(* Remote endpoint *)
Read the <users> from the <url: "https://api.example.com/users">.

(* Same syntax, same semantics *)
```

### 1.3 Benefits

1. **Consistency**: Single mental model for data retrieval
2. **Interchangeability**: Swap local/remote sources without code changes
3. **Simplicity**: No need to learn separate HTTP actions for basic operations
4. **Format-Aware**: Automatic content-type detection and parsing (ARO-0040)

---

## 2. Read from URL

### 2.1 Basic Syntax

```aro
Read the <result> from the <url: "https://example.com/api/data">.
```

This performs an HTTP GET request and binds the response body to `result`.

### 2.2 Automatic Format Detection

The response is automatically parsed based on `Content-Type` header:

| Content-Type | Parsed As |
|--------------|-----------|
| `application/json` | Dictionary/Array |
| `application/xml`, `text/xml` | Dictionary |
| `text/csv` | Array of rows |
| `text/yaml`, `application/x-yaml` | Dictionary |
| `text/plain` | String |
| `text/html` | String |
| (other) | Raw bytes/String |

```aro
(* API returns JSON → automatically parsed *)
Read the <users> from the <url: "https://api.example.com/users">.
Extract the <first-user> from the <users: 0>.

(* API returns CSV → automatically parsed as array *)
Read the <records> from the <url: "https://data.example.com/export.csv">.
```

### 2.3 Request Options via `with` Clause

```aro
(* Custom headers *)
Read the <data> from the <url: "https://api.example.com/data"> with {
    headers: {
        Authorization: "Bearer ${token}",
        Accept: "application/json"
    }
}.

(* Timeout configuration *)
Read the <response> from the <url: "https://slow-api.example.com/data"> with {
    timeout: 30
}.

(* Full options *)
Read the <result> from the <url: "https://api.example.com/resource"> with {
    headers: {
        Authorization: "Bearer ${api-key}",
        Accept: "application/json",
        X-Custom-Header: "value"
    },
    timeout: 60,
    encoding: "utf-8",
    follow-redirects: true,
    max-redirects: 5
}.
```

### 2.4 Options Reference (Read)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `headers` | Map | `{}` | HTTP request headers |
| `timeout` | Integer | `30` | Request timeout in seconds |
| `encoding` | String | `"utf-8"` | Response body encoding |
| `follow-redirects` | Boolean | `true` | Follow HTTP redirects |
| `max-redirects` | Integer | `10` | Maximum redirect hops |

---

## 3. Write to URL

### 3.1 Basic Syntax

```aro
Write the <data> to the <url: "https://api.example.com/submit">.
```

This performs an HTTP POST request with `data` as the request body.

### 3.2 Automatic Content-Type

The `Content-Type` header is automatically set based on the data type:

| Data Type | Content-Type |
|-----------|--------------|
| Dictionary/Array | `application/json` |
| String | `text/plain` |
| Bytes | `application/octet-stream` |

```aro
(* Sends as JSON *)
Write the <user> to the <url: "https://api.example.com/users">.

(* user = { name: "Alice", email: "alice@example.com" } *)
(* Content-Type: application/json *)
(* Body: {"name":"Alice","email":"alice@example.com"} *)
```

### 3.3 Request Options via `with` Clause

```aro
(* Custom headers *)
Write the <payload> to the <url: "https://api.example.com/data"> with {
    headers: {
        Authorization: "Bearer ${token}",
        Content-Type: "application/xml"
    }
}.

(* Timeout and encoding *)
Write the <large-data> to the <url: "https://api.example.com/upload"> with {
    timeout: 120,
    encoding: "utf-8"
}.

(* Full options *)
Write the <submission> to the <url: "https://api.example.com/submit"> with {
    headers: {
        Authorization: "Bearer ${api-key}",
        X-Request-ID: "${request-id}"
    },
    timeout: 60,
    content-type: "application/json",
    encoding: "utf-8"
}.
```

### 3.4 Options Reference (Write)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `headers` | Map | `{}` | HTTP request headers |
| `timeout` | Integer | `30` | Request timeout in seconds |
| `content-type` | String | (auto) | Override Content-Type header |
| `encoding` | String | `"utf-8"` | Request body encoding |

### 3.5 Response Handling

Write returns a response object with status and optional body:

```aro
Write the <user> to the <url: "https://api.example.com/users">.
(* Response is bound to a magic variable *)
Extract the <status> from the <response: status>.
Extract the <created-id> from the <response: body.id>.
```

Or capture explicitly:

```aro
Write the <created-user: user> to the <url: "https://api.example.com/users">.
(* created-user contains the response body *)
```

---

## 4. URL Detection

### 4.1 Automatic Protocol Detection

The `url` system object is recognized by protocol prefix:

```aro
(* Explicit url syntax *)
Read the <data> from the <url: "https://api.example.com/data">.

(* File paths use file syntax *)
Read the <data> from the <file: "./local/data.json">.
```

### 4.2 Variable URLs

```aro
(* URL from variable *)
Extract the <endpoint> from the <config: api.endpoint>.
Read the <data> from the <url: endpoint>.

(* Or with string interpolation *)
Read the <user> from the <url: "https://api.example.com/users/${user-id}">.
```

---

## 5. Error Handling

### 5.1 HTTP Errors

HTTP errors follow ARO's error philosophy—the code is the error message:

```aro
Read the <data> from the <url: "https://api.example.com/data">.
```

If the request fails, the error message clearly indicates what happened:

```
Cannot read the data from the url: https://api.example.com/data.
  HTTP 404: Not Found
  Feature: Fetch User Data
  Business Activity: User Service
```

### 5.2 Network Errors

```
Cannot read the data from the url: https://api.example.com/data.
  Connection refused
  Feature: Fetch User Data
  Business Activity: User Service
```

### 5.3 Timeout Errors

```
Cannot read the data from the url: https://api.example.com/data.
  Request timeout (30s exceeded)
  Feature: Fetch User Data
  Business Activity: User Service
```

---

## 6. Examples

### 6.1 Fetching JSON Data

```aro
(Fetch Users: User Service) {
    Read the <users> from the <url: "https://api.example.com/users">.
    Return an <OK: status> with <users>.
}
```

### 6.2 Authenticated Request

```aro
(Fetch Protected Data: API Client) {
    Get the <api-key> from the <env: "API_KEY">.

    Read the <data> from the <url: "https://api.example.com/protected"> with {
        headers: {
            Authorization: "Bearer ${api-key}"
        }
    }.

    Return an <OK: status> with <data>.
}
```

### 6.3 Submit Form Data

```aro
(Submit Order: Order Service) {
    Extract the <order> from the <request: body>.

    Write the <order> to the <url: "https://fulfillment.example.com/orders"> with {
        headers: {
            Authorization: "Bearer ${service-token}",
            X-Correlation-ID: "${correlation-id}"
        },
        timeout: 60
    }.

    Return a <Created: status> with <order>.
}
```

### 6.4 Data Pipeline: Remote to Local

```aro
(Sync Remote Data: Data Pipeline) {
    (* Fetch from remote API *)
    Read the <remote-data> from the <url: "https://api.example.com/export">.

    (* Write to local file *)
    Write the <remote-data> to the <file: "./data/snapshot.json">.

    Return an <OK: status> for the <sync>.
}
```

### 6.5 Data Pipeline: Local to Remote

```aro
(Upload Report: Reporting Service) {
    (* Read local file *)
    Read the <report> from the <file: "./reports/daily.json">.

    (* Upload to remote endpoint *)
    Write the <report> to the <url: "https://reporting.example.com/upload">.

    Return an <OK: status> for the <upload>.
}
```

---

## 7. Implementation Notes

### 7.1 Action Resolution

The Read and Write actions detect the system object type:

```
Read the <X> from the <Y: Z>.
                      ^
                      |
              +-------+-------+
              |               |
           "file"           "url"
              |               |
              v               v
        FileSystemService  HTTPClientService
```

### 7.2 HTTP Client Integration

URL operations use the existing `AROHTTPClient` service:

- Read → `GET` request
- Write → `POST` request

### 7.3 Format Detection Priority

1. Explicit `Content-Type` header in response/request
2. URL file extension (e.g., `.json`, `.csv`)
3. Content sniffing (JSON detection, XML detection)
4. Default to string/raw

---

## 8. Relationship to Existing Actions

### 8.1 Fetch Action

The `Fetch` action remains available for more complex HTTP operations:

```aro
(* Simple GET - use Read *)
Read the <data> from the <url: "https://api.example.com/data">.

(* Complex HTTP with method control - use Fetch *)
Fetch the <result> from the <endpoint: "https://api.example.com"> with {
    method: "PUT",
    body: <payload>,
    headers: { ... }
}.
```

### 8.2 Call Action

The `Call` action remains for RPC-style invocations:

```aro
(* Service-to-service RPC *)
Call the <result> from the <payment-service: "charge"> with <payment>.
```

### 8.3 Summary

| Action | Use Case |
|--------|----------|
| `Read ... from <url:>` | HTTP GET (data retrieval) |
| `Write ... to <url:>` | HTTP POST (data submission) |
| `Fetch` | Full HTTP control (any method) |
| `Call` | RPC/service invocation |

---

## 9. Future Extensions

### 9.1 Other HTTP Methods

Future proposals may extend the unified syntax:

```aro
(* Potential future syntax *)
Update the <user> at the <url: "https://api.example.com/users/123">.  (* PUT *)
Delete the <resource> at the <url: "https://api.example.com/items/456">.  (* DELETE *)
```

### 9.2 Streaming

Large responses could support streaming:

```aro
Stream the <data> from the <url: "https://api.example.com/large-export">.
```

---

## 10. Summary

This proposal unifies file and URL I/O under the familiar Read/Write syntax:

| Operation | File | URL |
|-----------|------|-----|
| Read (GET) | `Read <X> from <file: "path">` | `Read <X> from <url: "https://...">` |
| Write (POST) | `Write <X> to <file: "path">` | `Write <X> to <url: "https://...">` |

Both support the `with` clause for options (headers, timeout, encoding), and both benefit from automatic format detection (ARO-0040).
