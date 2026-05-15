# Build an HTTP client demo

Create a single-file ARO application that demonstrates making HTTP requests using the `Request` action.

In the `Application-Start` feature set:

1. Create an API URL pointing to a weather API endpoint (e.g., `http://127.0.0.1:18765/v1/forecast?latitude=52.52&longitude=13.41&current_weather=true`).

2. Make a simple GET request using `Request the <response> from the <api-url>`. Extract the body from the response using `Extract the <weather> from the <response: body>`. Log the weather data.

3. Make a second request with a custom timeout configuration: `Request the <response2> from the <api-url> with { timeout: 10 }`. Extract and log the response body.

Return OK at the end.
