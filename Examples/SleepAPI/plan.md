# Build an HTTP API demonstrating concurrent Sleep

Create an ARO application with two endpoints that sleep for different durations, demonstrating that concurrent requests sleep independently.

- `openapi.yaml` -- Define an API on `http://localhost:8095` with `GET /fast` (operationId: `fastSleep`, sleeps 1s) and `GET /slow` (operationId: `slowSleep`, sleeps 3s).

- `main.aro` -- Three feature sets:
  1. `Application-Start: Sleep API` -- Start HTTP server, Keepalive, return OK.
  2. `fastSleep: Sleep API` -- `Sleep the <pause> for 1 second`. Return OK.
  3. `slowSleep: Sleep API` -- `Sleep the <pause> for 3 seconds`. Return OK.

When both endpoints are called concurrently, total wall-clock time is ~3s (not 4s) because the sleeps are non-blocking and run in separate tasks.
