# Build an HTTP response headers demo

Create an ARO application that demonstrates accessing HTTP response headers, status code, and body from a Request result.

- `openapi.yaml` -- Define an API with `GET /demo` (operationId: `getDemoData`).

- `main.aro` -- Two feature sets:
  1. `Application-Start` -- Start the HTTP server with contract. Sleep 500 milliseconds to let the server start. Extract the server port from `<http-server: port>`, compute the URL dynamically, and make a request using `Request the <response> from the <url>`. Extract status from `<response: status>`, headers from `<response: headers>`, and body from `<response: body>`. Then extract nested fields from the body (e.g., temperature). Also show backward compatibility: body keys are accessible directly on the response object.
  2. `getDemoData` -- Returns sample data `{ temperature: 22.5, latitude: 52.52, city: "Berlin" }`.
