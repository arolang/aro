# Chapter 6: Extend

*"The REPL is not isolated. It can reach the world."*

---

## Beyond the Prompt

The REPL isn't just for local calculations. It connects to the outside world:

- HTTP servers
- File watchers
- Plugins
- External services

All from the same prompt.

## Starting an HTTP Server

```
aro> :service start http --port 3000
HTTP server started on http://localhost:3000
```

That's it. A server is running. Now define handlers:

```
aro> (healthCheck: API) {
(healthCheck)> Return an <OK: status> with { status: "healthy" }.
(healthCheck)> }
Feature set 'healthCheck' defined
```

The feature set becomes an endpoint. Call it from anywhere:

```bash
$ curl http://localhost:3000/health
{"status":"healthy"}
```

## Managing Services

See what's running:

```
aro> :services
┌────────────┬─────────────┬─────────┬──────────┐
│ Name       │ Type        │ Status  │ Details  │
├────────────┼─────────────┼─────────┼──────────┤
│ http-a1b2  │ http-server │ running │ :3000    │
└────────────┴─────────────┴─────────┴──────────┘
```

Stop when done:

```
aro> :service stop http-a1b2
HTTP server stopped
```

## Installing Plugins from Git

Plugins extend ARO with new actions. Install them directly from Git:

```
aro> /plugin add git@github.com:arolang/plugin-rust-csv.git
Plugin 'plugin-rust-csv' v1.0.0 installed and loaded (commit: 7b2e4f1)
  [+] Rust plugin built
Actions: ParseCSV, FormatCSV
```

Install a specific version:

```
aro> /plugin add git@github.com:arolang/plugin-swift-hello.git --ref v2.0.0
Plugin 'plugin-swift-hello' v2.0.0 installed and loaded (commit: a3f9c21)
  [+] Swift sources ready
Actions: Greet
```

Now use them:

```
aro> Greet the <message> with "World".
=> "Hello, World!"
```

New verbs. New capabilities. Same syntax.

The plugin is cloned, built, and loaded in one step. REPL plugins are stored in `~/.aro/repl-plugins/` and persist across sessions.

## Listing Plugins

```
aro> /plugin list
Name               | Version | Handle | Status
-------------------|---------|--------|-------
plugin-rust-csv    | 1.0.0   | CSV    | loaded
plugin-swift-hello | 2.0.0   | Hello  | loaded
```

## Removing Plugins

Unload a plugin from the session:

```
aro> /plugin remove plugin-swift-hello
Plugin 'plugin-swift-hello' unloaded
```

The actions disappear. The session continues.

## File Watching

Monitor directories:

```
aro> :service start file-watcher --path ./data
File watcher started on ./data

aro> (File Handler: File Event Handler) {
(File Handler)> Extract the <path> from the <event: path>.
(File Handler)> Log "Changed: ${<path>}" to the <console>.
(File Handler)> }
Feature set registered for file events
```

Touch a file in `./data`. See the log appear.

---

**Next: Chapter 7 — Depart**
