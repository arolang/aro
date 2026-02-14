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
(healthCheck)> <Return> an <OK: status> with { status: "healthy" }.
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

## Loading Plugins

Plugins extend ARO with new actions:

```
aro> :plugin load ./Plugins/json-tools
Loading plugin: json-tools
  Type: rust-plugin
  Actions: validate-json, format-json, minify-json
Plugin loaded successfully
```

Now use them:

```
aro> <Set> the <data> to { name: "test", valid: true }.
=> OK

aro> <Validate-json> the <result> from the <data>.
=> { valid: true, errors: [] }
```

New verbs. New capabilities. Same syntax.

## Listing Plugins

```
aro> :plugins
┌─────────────┬──────┬─────────────────────────────┐
│ Name        │ Type │ Actions                     │
├─────────────┼──────┼─────────────────────────────┤
│ json-tools  │ rust │ validate-json, format-json  │
└─────────────┴──────┴─────────────────────────────┘
```

## Plugin Hot Reload

Developing a plugin? Watch for changes:

```
aro> :plugin load ./Plugins/my-plugin --watch
Plugin loaded with file watching enabled

# Edit plugin source...

[Plugin recompiled automatically]
Reloaded: my-plugin (2 actions)
```

Change code, test immediately. No restart needed.

## File Watching

Monitor directories:

```
aro> :service start file-watcher --path ./data
File watcher started on ./data

aro> (File Handler: File Event Handler) {
(File Handler)> <Extract> the <path> from the <event: path>.
(File Handler)> <Log> "Changed: ${<path>}" to the <console>.
(File Handler)> }
Feature set registered for file events
```

Touch a file in `./data`. See the log appear.

---

**Next: Chapter 7 — Depart**
