# Build a unified URL I/O client

Create a single-file ARO application that demonstrates using `Read` and `Write` with URLs for HTTP operations.

In the `Application-Start` feature set:

1. **GET request** -- `Read the <todo> from the <url: "https://jsonplaceholder.typicode.com/todos/1">`. Response is auto-parsed as JSON. Extract title and completed fields.

2. **GET with custom headers** -- `Read the <headers-test> from the <url: "https://httpbin.org/headers"> with { headers: { X-Custom-Header: "ARO-URL-Client", Accept: "application/json" } }`.

3. **POST request** -- Create data and `Write the <new-post> to the <url: "https://jsonplaceholder.typicode.com/posts">`.

4. **Fetch user** -- Read user data from URL, extract name and email.

Log all results and return OK.
