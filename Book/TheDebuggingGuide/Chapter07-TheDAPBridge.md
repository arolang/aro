# Chapter 7: The DAP Bridge

*"The same debugger lives behind your `aro debug` prompt and behind your editor's pause icon."*

---

## 7.1 What DAP gives you

The Debug Adapter Protocol is the wire language editors speak to debuggers. Microsoft defined it for VS Code; everyone else adopted it. When the debugger speaks DAP, it talks to:

- **VS Code** via the `aro-language` extension
- **IntelliJ IDEA** / PyCharm / Rider via the `intellij-aro` plugin's Debug run-configuration
- **Neovim** via `nvim-dap` and a launch configuration
- Any other DAP-compatible editor (Helix, Zed, Sublime LSP, et al.)

Pause, step, continue, breakpoints, threads, scopes, variables — every action that has a button in the editor's debug pane maps to one DAP request the `aro` binary handles.

## 7.2 Stdio vs TCP

Two transport modes ship in v1:

- **Stdio** — the editor spawns `aro debug --dap path/to/project`, talks over the child process's stdin/stdout. Standard launch-config flow. No port to manage, no firewall question.
- **TCP** — the binary is launched independently (`aro debug --dap-port 4711 path/to/project`), the editor attaches over `127.0.0.1:4711`. Useful for production-attach style flows where the program is already running and you want to point your editor at it.

Both transports speak the same protocol; the difference is who starts whom.

## 7.3 VS Code

The extension lives at `Editor/vscode-aro/`. After installation (`code --install-extension aro-language-*.vsix` or via the Marketplace once published), the Debug pane gets an "ARO Debugger" entry.

A minimal launch.json:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "type": "aro",
      "request": "launch",
      "name": "Debug current ARO project",
      "program": "${workspaceFolder}",
      "stopOnEntry": true
    }
  ]
}
```

Press F5. The extension spawns `aro debug --dap` with your `program` path, the runtime hits the entry pause, VS Code's Debug pane lights up. Set breakpoints by clicking in the gutter; the gutter dots are sent over DAP as `setBreakpoints` requests, mapped to location breakpoints (chapter 5.2) on the controller.

Variables show the current `PauseInfo.symbols` snapshot. Call Stack shows the causal chain (chapter 4.5).

The extension also adds a command **"ARO: Start Debugging"** that creates a launch config on the fly if none exists — useful for quick "I just want to debug this one file" sessions.

## 7.4 IntelliJ

The IntelliJ plugin (1.4.3+) ships an **ARO Application** run-configuration. To debug:

1. Edit your run configuration.
2. Set **Command** to `Debug (step debugger)`.
3. Optionally set **DAP mode** to enable the IDE's debug toolbar (or leave off for a console TUI session).
4. Optionally add initial breakpoints (line numbers or verb names, comma-separated).

When you press Debug, the plugin invokes `aro debug --dap` and feeds the stream through IntelliJ's debugger UI. Breakpoints set in the gutter behave the same as in VS Code.

A common gotcha: IntelliJ's new-UI run toolbar touches options eagerly. If your plugin version is older than 1.4.3, the toolbar throws a `ClassCastException` on hover. Update to 1.4.3 or newer.

## 7.5 Neovim with nvim-dap

The Neovim path is identical in spirit. A typical `dap.adapters` entry:

```lua
local dap = require('dap')

dap.adapters.aro = {
  type = "executable",
  command = "aro",
  args = { "debug", "--dap" }
}

dap.configurations.aro = {
  {
    type = "aro",
    request = "launch",
    name = "Debug current ARO project",
    program = "${workspaceFolder}",
    stopOnEntry = true,
  }
}
```

`<F5>` (or your `:lua require('dap').continue()` keybind) starts a session. The standard `nvim-dap` keymap covers everything: `<F10>` next, `<F11>` step in, `<F12>` step out, `<S-F5>` stop. Breakpoints set with `:lua require('dap').toggle_breakpoint()` map to location breakpoints.

## 7.6 What's identical across editors

All three editors:

- Set / clear / list location breakpoints via DAP `setBreakpoints`.
- Step / continue / pause via DAP step requests.
- Show the current symbol snapshot via DAP `variables`.
- Print program output via DAP `output` events.
- Show the pause reason in the editor's status bar.

The CLI TUI is functionally identical — same controller, same breakpoint state. If you switch editor mid-project, every breakpoint stays where it was.

## 7.7 What's not yet identical

A few features exist in the TUI but not in DAP yet:

- **Watch expressions** — the DAP `variables` response returns the symbol snapshot, but custom watch expressions added via the CLI are not surfaced to the editor's Watch pane in v1. (DAP has an `evaluate` request for this; wiring it up is in #230 follow-ups.)
- **Conditional breakpoints** — DAP `setBreakpoints` accepts a `condition` field, but the bridge currently passes location-only and falls back to the unconditional location case. Set conditional breakpoints from the CLI for now.
- **Event / error-any breakpoints** — no DAP UI primitive. Set them from the CLI before attaching, or via the launch config's `breakpoint` array.

The asymmetry is documented in `aro debug --help`'s DAP section and tracked in issue #230 as a "DAP parity" follow-up.

## 7.8 Debugging the DAP bridge itself

If something goes wrong:

```bash
aro debug --dap --dap-log /tmp/dap.log path/to/project
```

The `--dap-log` flag mirrors every message in and out of the bridge to a file. Diffing this against the editor's own "DAP trace" view (Settings → Debug → Adapter trace) is the fastest way to spot a mismatch — usually a missing field or a request the bridge doesn't handle yet, which logs as `unhandled: <command>` in the trace.

---

**Next:** Chapter 8 covers what `lldb` does and does not see when you run `aro build` and try to debug the resulting native binary — and why the interpreter path is the primary recommendation.
