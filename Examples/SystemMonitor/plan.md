# Build a system monitor HTTP API

Create an ARO application that exposes system commands through an HTTP API using the `Exec` action.

- `openapi.yaml` -- Define an API on `http://localhost:8080` with four GET endpoints: `/exec?cmd=<command>` (executeCommand), `/list?path=<path>` (listDirectory), `/disk` (checkDisk), `/processes` (listProcesses). Define an ExecResponse schema.

- `main.aro` -- Five feature sets:
  1. `Application-Start` -- Start HTTP server, log available endpoints, Keepalive.
  2. `executeCommand` -- Extract `cmd` from query parameters. Return BadRequest if empty. Use `Exec the <result> for the <command> with <cmd>` to run it. Return ServerError if error, OK otherwise.
  3. `listDirectory` -- Extract path from query parameters, default to ".". Build an `ls -la` command and execute it.
  4. `checkDisk` -- Execute `df -h`.
  5. `listProcesses` -- Execute `ps aux | head -20`.
