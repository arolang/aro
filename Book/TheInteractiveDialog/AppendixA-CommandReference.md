# Appendix A: Command Quick Reference

All commands work with both `:` and `/` prefix (e.g., `:help` or `/help`).

## Meta-Commands

| Command | Aliases | Description |
|---------|---------|-------------|
| `:help` | `:h`, `:?` | Show help message |
| `:vars` | `:v`, `:variables` | List all session variables |
| `:vars <name>` | | Show details of specific variable |
| `:type <name>` | `:t` | Show type of variable |
| `:clear` | `:c`, `:reset` | Clear all session state |
| `:history` | `:hist` | Show full command history |
| `:history <n>` | | Show last n commands |
| `:fs` | `:featuresets` | List defined feature sets |
| `:invoke <name>` | `:i`, `:run` | Invoke a feature set |
| `:invoke <name> <json>` | | Invoke with input data (quotes must be escaped — §4) |
| `:set <name> <value>` | | Set a variable |
| `:load <file>` | | Load and execute a `.aro` file |
| `:export` | `:e` | Print session as .aro code |
| `:export <file>` | | Save session to .aro file |
| `:export --test <file>` | | Export as test file |
| `:plugin add <git-url>` | `:plugins` | Install and load a plugin from Git |
| `:plugin add <url> --ref <ref>` | | Install specific version |
| `:plugin update <name>` | | Update a plugin (`--ref` to pin) |
| `:plugin list` | | List loaded plugins |
| `:plugin remove <name>` | | Unload and delete a plugin |
| `:quit` | `:q`, `:exit` | Exit the REPL |

There is no `:save`, and no `:service` / `:services`. Services start with an
ordinary ARO statement (`Start the <file-monitor> with "./data".`), which is
chapter 6.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Tab` | Auto-complete |
| `Up` / `Ctrl+P` | Previous command |
| `Down` / `Ctrl+N` | Next command |
| `Ctrl+A` / `Ctrl+E` | Start / end of line |
| `Ctrl+B` / `Ctrl+F` | Left / right one character |
| `Ctrl+C` | Cancel current input |
| `Ctrl+D` | Exit REPL (on empty line) |
| `Ctrl+L` | Clear screen |
| `Ctrl+U` | Clear line |
| `Ctrl+K` | Delete to end of line |
| `Ctrl+W` | Delete word backward |
| `Ctrl+T` | Transpose characters |

`Ctrl+R` reverse history search is *not* bound.

## Result Display

| Symbol | Meaning |
|--------|---------|
| `=> <value>` | A bare expression evaluated to a value |
| `=> OK` | Statement succeeded (a binding statement always reports this) |
| `Error: ...` | Statement failed |
| `+` | Statement added to feature set |
| `...>` | Continuation (unclosed brace, bracket, paren or string) |
| `(Name)>` | Inside feature set definition |
| `[Name] ...` | Program output, prefixed with the feature set that logged it |
