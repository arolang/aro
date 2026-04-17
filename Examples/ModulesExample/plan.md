# Build a modular application with imports

Create a ModulesExample with three sub-applications demonstrating the `import` statement.

- `ModuleA/` -- A standalone application with `main.aro` (Application-Start that starts HTTP server with contract, Keepalive, returns OK) and a `getModuleA` feature set returning `{ message: "Hello from Module A" }`. Include `openapi.yaml` with `GET /module-a`.

- `ModuleB/` -- Same structure as ModuleA but with `getModuleB` returning "Hello from Module B" and `openapi.yaml` with `GET /module-b`.

- `Combined/` -- A combined application that uses `import ../ModuleA` and `import ../ModuleB` to include both modules. Its `main.aro` has Application-Start, starts the HTTP server, and uses Keepalive. Its `openapi.yaml` defines both `/module-a` and `/module-b` endpoints. The imported feature sets handle the requests without needing to be redefined.

Each module can run standalone or be imported into the combined application.
