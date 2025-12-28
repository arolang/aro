# Chapter 12: OpenAPI Integration

*"Your contract is your router."*

---

## 12.1 Contract-First Development

<div style="float: right; margin: 0 0 1em 1.5em;">
<svg width="180" height="200" viewBox="0 0 180 200" xmlns="http://www.w3.org/2000/svg">  <!-- OpenAPI file -->  <rect x="50" y="10" width="80" height="45" rx="4" fill="#fef3c7" stroke="#f59e0b" stroke-width="2"/>  <text x="90" y="28" text-anchor="middle" font-family="monospace" font-size="9" font-weight="bold" fill="#92400e">openapi.yaml</text>  <text x="90" y="42" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#b45309">operationId:</text>  <text x="90" y="52" text-anchor="middle" font-family="monospace" font-size="7" fill="#d97706">listUsers</text>  <!-- Arrow down -->  <line x1="90" y1="55" x2="90" y2="75" stroke="#6b7280" stroke-width="2"/>  <polygon points="90,75 85,67 95,67" fill="#6b7280"/>  <!-- Router box -->  <rect x="40" y="80" width="100" height="30" rx="4" fill="#e0e7ff" stroke="#6366f1" stroke-width="2"/>  <text x="90" y="100" text-anchor="middle" font-family="sans-serif" font-size="9" font-weight="bold" fill="#4338ca">Route Matcher</text>  <!-- Arrow down -->  <line x1="90" y1="110" x2="90" y2="130" stroke="#6b7280" stroke-width="2"/>  <polygon points="90,130 85,122 95,122" fill="#6b7280"/>  <!-- Feature Set -->  <rect x="30" y="135" width="120" height="50" rx="4" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="90" y="152" text-anchor="middle" font-family="monospace" font-size="8" fill="#166534">(listUsers: User API)</text>  <text x="90" y="165" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#22c55e">&lt;Retrieve&gt;...</text>  <text x="90" y="178" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#22c55e">&lt;Return&gt;...</text>  <!-- Label -->  <text x="90" y="198" text-anchor="middle" font-family="sans-serif" font-size="7" fill="#9ca3af">name = operationId</text></svg>
</div>

ARO embraces contract-first API development. Rather than defining routes in code and hoping documentation stays synchronized, you define your API in an OpenAPI specification file, and ARO uses that specification to configure routing automatically. The specification is the source of truth; the code implements what the specification declares.

This approach inverts the typical relationship between code and documentation. In most frameworks, you write code and generate documentation from it. In ARO, you write the specification and implement handlers for it. The specification comes first, defining what the API looks like from a client's perspective. The implementation comes second, fulfilling the promises made by the specification.

The connection between specification and code is the operation identifier. Each operation in your OpenAPI specification has an operationId that uniquely identifies it. When a request arrives, ARO determines which operation it matches based on the path and method, looks up the operationId, and triggers the feature set with that name. The feature set name becomes the operationId; the operationId becomes the feature set name.

This design ensures that your API cannot drift from its documentation. If the specification declares an operation, you must implement a feature set with that name, or clients receive an error. If you implement a feature set that does not correspond to an operation, it never receives HTTP requests. The specification and implementation are bound together.

---

## 12.2 The OpenAPI Requirement

ARO's HTTP server depends on the presence of an OpenAPI specification file. The file must be named openapi.yaml and must be located in the application directory alongside your ARO source files. Without this file, no HTTP server starts. No port is opened. No requests are received.

This requirement is deliberate. It enforces the contract-first philosophy at the framework level. You cannot accidentally create an undocumented API because the documentation is required for the API to exist. You cannot forget to update documentation when changing routes because changing routes means changing the specification.

The requirement also simplifies the runtime. There is no route registration API, no decorator syntax for paths, no configuration file for endpoints. The OpenAPI specification provides all of this information in a standard format that tools throughout the industry understand. Your API specification can be viewed in Swagger UI, validated with standard tools, and used to generate client libraries, all because it follows the OpenAPI standard.

If you are building an application that does not expose an HTTP API—a file processing daemon, a socket server, a command-line tool—you simply omit the openapi.yaml file. The application runs normally; it just does not handle HTTP requests.

---

## 12.3 Operation Identifiers

The operationId is the key that connects HTTP routes to feature sets. When you define an operation in your OpenAPI specification, you assign it an operationId. When you implement the handler in ARO, you create a feature set with that identifier as its name.

Operation identifiers should be descriptive verbs that indicate what the operation does. Common conventions include verb-noun patterns like listUsers, createOrder, getProductById, and deleteComment. The identifier should make sense when read in isolation, as it will appear in logs, error messages, and feature set declarations.

Each operation in your specification must have a unique operationId. The OpenAPI standard requires this, and ARO relies on it for routing. If two operations shared an identifier, there would be ambiguity about which feature set should handle which request. The uniqueness constraint eliminates this possibility.

When a request arrives that matches a path and method in your specification, ARO looks up the corresponding operationId and searches for a feature set with that name. If found, the feature set executes with the request context available for extraction. If not found, ARO returns a 501 Not Implemented response indicating that the operation exists in the specification but has no handler.

---

## 12.4 Route Matching

ARO matches incoming HTTP requests to operations through a two-step process. First, it matches the request path against the path templates in the specification. Second, it matches the HTTP method against the methods defined for that path. The combination of path and method identifies a unique operation.

Path templates can include parameters enclosed in braces. A template like /users/{id} matches paths like /users/123 or /users/abc. When a match occurs, the actual value from the URL is extracted and made available as a path parameter. The parameter name in the template (id in this example) becomes the key for accessing the value.

Multiple methods can be defined for the same path. The /users path might support GET for listing users and POST for creating users. Each method has its own operationId and its own feature set. A GET request to /users triggers listUsers; a POST request to /users triggers createUser. The path is the same, but the operations are different.

Requests that do not match any path receive a 404 response. Requests that match a path but use an undefined method receive a 405 Method Not Allowed response. These responses are generated automatically based on the specification; you do not write code to handle unmatched routes.

---

## 12.5 Starting the Server

The HTTP server starts when you execute the Start action with the http-server identifier and the contract preposition. This tells the runtime to read the OpenAPI specification, configure routing based on its contents, and begin accepting requests on the configured port.

The server typically starts during application initialization in the Application-Start feature set. After starting the server, you use the Keepalive action to keep the application running and processing requests. Without Keepalive, the application would start the server and immediately terminate.

You can configure the port on which the server listens. The default is typically 8080, but you can specify a different port using the "on port" syntax or provide a full host and port string. This flexibility allows you to run multiple services on different ports or to conform to container orchestration requirements.

The server starts synchronously during initialization. If the port is already in use or binding fails for any other reason, the startup fails with an appropriate error. This fail-fast behavior ensures you know immediately if the server cannot start, rather than discovering the problem later when requests fail.

---

## 12.6 Schema Validation

OpenAPI specifications can include schemas that define the structure and constraints of request bodies and responses. ARO can validate incoming requests against these schemas, rejecting invalid requests before they reach your feature set.

Automatic validation can be enabled when starting the server. With validation enabled, the runtime checks each incoming request body against the schema defined in the specification. If the request does not conform, the client receives a 400 response with details about which validations failed.

Manual validation is an alternative when you want more control. You extract the request body and then validate it explicitly using the Validate action with a reference to the schema. This approach lets you perform additional processing before or after validation, or handle validation failures in custom ways.

Schema validation provides a first line of defense against malformed requests. It ensures that your feature set receives data in the expected structure with the expected types. This eliminates the need for defensive type checking in your business logic and catches problems at the API boundary where they can be reported clearly to clients.

---

## 12.7 Best Practices

Design your API specification before writing implementation code. Think about what resources your API exposes, what operations clients need to perform, and what data structures are involved. Write this design down in OpenAPI format. Then implement feature sets to fulfill the specification.

Choose operation identifiers that describe what the operation does in clear, consistent terms. Use verb-noun patterns like listUsers, createOrder, getProductById. Avoid generic names like "handle" or "process" that do not convey meaning. The identifier appears in your feature set declarations, in logs, and in error messages, so clarity matters.

Group related operations using tags in your OpenAPI specification. Tags help organize documentation and make the specification easier to navigate. A user management API might tag all user-related operations with "Users" and all authentication operations with "Auth."

Document the possible responses for each operation. Clients need to know not just the success response but also what error responses they might receive and under what conditions. This documentation helps API consumers handle all cases appropriately.

Keep your specification and implementation synchronized. When you change the API, update the specification first, then update the implementation. When you add new operations, add them to the specification first. The contract should always accurately reflect what the API does.

---

> **See Chapter 13** for detailed coverage of HTTP feature sets, including request data access, CRUD operations, response patterns, and authentication.

---

*Next: Chapter 13 — HTTP Feature Sets*
