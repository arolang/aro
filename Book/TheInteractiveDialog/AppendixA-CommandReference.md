# Appendix A: Command Quick Reference

All commands work with both `:` and `/` prefix (e.g., `:help` or `/help`).

## Meta-Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `:help` | `:h`, `:?` | Show help message |
| `:vars` | `:v` | List all session variables |
| `:vars <name>` | | Show details of specific variable |
| `:type <name>` | `:t` | Show type of variable |
| `:clear` | `:c` | Clear all session state |
| `:history` | `:hist` | Show full command history |
| `:history <n>` | | Show last n commands |
| `:fs` | | List defined feature sets |
| `:invoke <name>` | `:i` | Invoke a feature set |
| `:invoke <name> <json>` | | Invoke with input data |
| `:set <name> <value>` | | Set a variable |
| `:save <file>` | | Save session to file |
| `:load <file>` | | Load and execute file |
| `:export` | `:e` | Print session as .aro code |
| `:export <file>` | | Save session to .aro file |
| `:export --test <file>` | | Export as test file |
| `:services` | `:svc` | List active services |
| `:service start <type>` | | Start a service |
| `:service stop <name>` | | Stop a service |
| `:plugin add <git-url>` | | Install and load a plugin from Git |
| `:plugin add <url> --ref <ref>` | | Install specific version |
| `:plugin list` | `:plugins` | List loaded plugins |
| `:plugin remove <name>` | | Unload a plugin |
| `:quit` | `:q`, `:exit` | Exit the REPL |

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Tab` | Auto-complete |
| `Up` | Previous command |
| `Down` | Next command |
| `Ctrl+R` | Reverse search history |
| `Ctrl+C` | Cancel current input |
| `Ctrl+D` | Exit REPL (on empty line) |
| `Ctrl+L` | Clear screen |
| `Ctrl+U` | Clear line |
| `Ctrl+W` | Delete word backward |

## Service Types

| Type | Option | Description |
|------|--------|-------------|
| `http` | `--port <n>` | HTTP server |
| `http` | `--contract <file>` | OpenAPI contract |
| `file-watcher` | `--path <dir>` | File monitor |
| `socket` | `--port <n>` | TCP socket server |

## Result Display

| Symbol | Meaning |
|--------|---------|
| `=> <value>` | Statement returned a value |
| `=> OK` | Statement succeeded (no value) |
| `Error: ...` | Statement failed |
| `+` | Statement added to feature set |
| `...>` | Continuation (incomplete input) |
| `(Name)>` | Inside feature set definition |
