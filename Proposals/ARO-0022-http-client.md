# ARO-0022: HTTP Client

* Proposal: ARO-0022
* Author: ARO Language Team
* Status: **Draft**
* Requires: ARO-0020, ARO-0016

## Abstract

This proposal defines HTTP client capabilities for ARO applications using AsyncHTTPClient, enabling outgoing HTTP requests to external services.

## Motivation

Applications often need to consume external APIs. ARO needs:

1. **HTTP Requests**: Make GET, POST, PUT, DELETE requests
2. **Response Handling**: Parse and process HTTP responses
3. **Error Handling**: Handle network errors gracefully
4. **Integration**: Work with the event system

## Proposed Solution

### 1. HTTP Request Actions

Use `<Fetch>` or `<Call>` for HTTP requests:

```aro
(* GET request *)
<Fetch> the <users> from the <api: /users>.

(* POST request *)
<Call> the <result> via <api: POST /users> with <user-data>.

(* With full URL *)
<Fetch> the <data> from "https://api.example.com/endpoint".
```

### 2. API Definition

Define external APIs:

```aro
api UserAPI {
    baseUrl: "https://api.example.com/v1";
    headers: {
        "Authorization": "Bearer ${token}",
        "Content-Type": "application/json"
    };
}
```

### 3. Request Methods

```aro
(* GET *)
<Fetch> the <users> from <UserAPI: GET /users>.

(* POST *)
<Call> the <user> via <UserAPI: POST /users> with <data>.

(* PUT *)
<Call> the <updated> via <UserAPI: PUT /users/{id}> with <data>.

(* DELETE *)
<Call> the <result> via <UserAPI: DELETE /users/{id}>.

(* PATCH *)
<Call> the <patched> via <UserAPI: PATCH /users/{id}> with <partial-data>.
```

### 4. Response Processing

```aro
<Fetch> the <response> from <api: /data>.
<Extract> the <status-code> from the <response: statusCode>.
<Extract> the <body> from the <response: body>.
<Transform> the <json: data> from the <body>.
```

### 5. Error Handling

```aro
<Fetch> the <response> from <api: /resource>.

if <response: statusCode> is 404 then {
    <Throw> a <NotFoundError> for the <missing: resource>.
}

if <response: statusCode> >= 500 then {
    <Throw> a <ServerError> for the <external: service>.
}
```

### 6. AsyncHTTPClient Integration

The runtime uses AsyncHTTPClient:

```swift
public final class AROHTTPClient: HTTPClientService {
    private let client: HTTPClient

    public func get(url: String) async throws -> any Sendable {
        let request = HTTPClientRequest(url: url)
        let response = try await client.execute(request, timeout: timeout)
        return HTTPClientResponse(response)
    }

    public func post(url: String, body: any Sendable) async throws -> any Sendable {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.body = .bytes(ByteBuffer(data: bodyData))
        let response = try await client.execute(request, timeout: timeout)
        return HTTPClientResponse(response)
    }
}
```

---

## Grammar Extension

```ebnf
(* API definition *)
api_definition = "api" , identifier , "{" , api_config , "}" ;
api_config = { api_property } ;
api_property = property_name , ":" , value , ";" ;

(* API call in object clause *)
api_call = api_name , ":" , [ http_method ] , route_path ;
```

---

## Complete Example

```aro
(* Define external API *)
api WeatherAPI {
    baseUrl: "https://api.weather.com/v1";
    headers: { "API-Key": "${WEATHER_API_KEY}" };
}

(Get Weather: External Service) {
    <Extract> the <city> from the <request: query city>.

    (* Fetch weather data *)
    <Fetch> the <weather-response> from <WeatherAPI: GET /weather?city=${city}>.

    (* Check for errors *)
    <Extract> the <status> from the <weather-response: statusCode>.

    if <status> is not 200 then {
        <Throw> a <WeatherError> for the <api: failure>.
    }

    (* Extract and return data *)
    <Extract> the <weather-data> from the <weather-response: body>.
    <Return> an <OK: status> with <weather-data>.
}
```

---

## Implementation Notes

- Uses AsyncHTTPClient for non-blocking requests
- Supports timeout configuration
- Emits events for request completion and errors
- Thread-safe for concurrent requests

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2024-12 | Initial specification |
