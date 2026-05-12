# Build a comprehensive scoping demo with HTTP endpoints and events

Create an ARO application that demonstrates all scoping mechanisms: local scope, published variables, business activity boundaries, framework-injected variables, transformation pipelines, and loop variable isolation.

The application needs two files:

- `openapi.yaml` -- Define an API on `http://localhost:8083` with two GET endpoints: `/config` (operationId: `getConfig`) and `/status` (operationId: `getStatus`).

- `main.aro` -- Contains four feature sets:

  1. `Application-Start: Scoping Demo` -- Create local variables `<app-name>` and `<version>` (only visible in this feature set). Create a `<config>` object combining them with a threshold, then `Publish as <shared-config> <config>` to make it visible across the "Scoping Demo" business activity. Demonstrate immutable transformation pipeline: create `<raw-text>`, compute `<upper-text: uppercase>` and `<text-length: length>` (each step produces a new binding). Demonstrate loop variable isolation with a list of tags, computing `<tag-length: length>` inside the loop. Emit an `<AppReady: event>` with the config. Start the HTTP server with contract, keepalive, and return OK.

  2. `getConfig: Scoping Demo` -- This handler can access `<shared-config>` because it shares the "Scoping Demo" business activity. Extract `<name>` and `<thresh>` from the shared config and return them as JSON.

  3. `getStatus: Scoping Demo` -- Also shares the business activity. Extract the version from shared config and return status JSON.

  4. `Log App Ready: AppReady Handler` -- This event handler has a DIFFERENT business activity ("AppReady Handler"), so it CANNOT access `<shared-config>`. Instead, it receives data through the framework-injected `<event>` variable. Extract the config payload from the event, then extract the name from it, and log it.
