# Chapter 10: Production Attach

*"A debugger that stalls every request isn't a debugger; it's an outage."*

---

## 10.1 The problem

The debugger described in chapters 1–9 pauses on every statement. That's exactly right for a local session against `Examples/HelloWorld`. It is catastrophically wrong for a live HTTP server handling a thousand requests a second. Each request would block at the entry pause, the load balancer would mark the instance unhealthy, you'd take the service down to set a breakpoint.

Two features make the debugger usable against a running production process: **sampling** and **TCP attach**. Use them together. Use them sparingly.

## 10.2 Sampling

The `--sample N` flag tells the controller to only enter the pause path on every Nth eligible checkpoint. Breakpoint matches still fire every time — sampling thins the *step-mode* stream, not the *user-requested* stream.

```bash
aro debug --sample 1000 ./MyApp
```

With `N=1000`, ninety-nine point nine percent of statement boundaries are silently skipped. The hot path stays a TaskLocal pointer load + a counter increment — measurably cheaper than a real pause and well under the 2% overhead budget. A statement-rate of 100k/s drops to 100 pauses/s with `N=1000`, which is comfortable for a local CLI to handle.

The right sample stride depends on your statement rate. Rules of thumb:

| Statement rate | Recommended `N` | Resulting pause rate |
|---|---|---|
| < 1k/s | 1 (no sampling) | full speed |
| 1k–10k/s | 100 | 10–100/s |
| 10k–100k/s | 1000 | 10–100/s |
| > 100k/s | 10000 | 10/s |

Breakpoint matches are unaffected by `N`. If you want to *only* see breakpoints (no step-mode pauses at all), set a giant `N`:

```bash
aro debug --sample 1000000 --breakpoint Emit ./MyApp
```

The runtime effectively never step-pauses; it only stops on `Emit`.

## 10.3 TCP attach

The other half is reaching the running process. The `--dap-port` flag binds `127.0.0.1:port`, accepts one DAP client, and feeds it to the same `DAPFrontend` chapter 7 described:

```bash
aro debug --dap-port 4711 --sample 1000 ./MyApp
```

This blocks until a client connects, then proceeds. From a developer machine on the same host (or via SSH port forward):

```bash
ssh -L 4711:localhost:4711 prod-host
# Then in VS Code's Run-and-Debug:
{ "type": "aro", "request": "attach", "host": "127.0.0.1", "port": 4711 }
```

The client speaks DAP exactly as it would for a local session. The runtime is the only thing that lives on the production host; the editor stays on your laptop.

One client at a time. If a second `attach` arrives while the first is connected, the second sees the TCP `accept` block — you have to disconnect the first to free the listener. (v1 limitation. Multi-client attach is on the v2 backlog.)

## 10.4 Pause-on-disconnect

If your editor crashes or you close the laptop lid, the DAP socket disconnects. The runtime sees EOF and the debugger frontend returns `.quit`, which throws `DebuggerQuit` from the next checkpoint — the program ends.

This is intentional for v1: an orphaned debugger session is worse than a clean exit. If you want the program to keep running after you detach, use *the TUI mode and the DAP mode mixed*: launch `aro debug --dap-port` in a tmux session that survives logout, attach and detach from your editor freely, and quit the tmux session when you're truly done. The next chapter on the v2 backlog is "detach-and-continue" semantics where disconnect leaves the program running.

## 10.5 What production attach is *not* for

Two things to be eyes-open about.

**It is not for fast iteration.** If you're trying to fix a bug, pull the production session into a recording, replay it locally (chapter 9), and iterate against the recording. The production process is for *observing* a state you cannot reproduce; it is not for trial-and-error.

**It is not free.** Even with `--sample 10000`, the hook itself runs on every statement boundary (it's the `if let controller = Debug.controller` check). The check is one pointer load and a nil-comparison — negligible in absolute terms but not zero. For a process that ships 100M statements/s, the cumulative cost is real. Measure before deploying long-running debug sessions to performance-sensitive paths.

In practice: if you're inside the perf budget for your service, the debugger is invisible. If you are *near* the budget, sample more aggressively or use a recording.

## 10.6 Recipe: production diagnostic session

A safe, repeatable recipe.

On the production host:

```bash
nohup aro debug --dap-port 4711 --sample 5000 --record /var/log/aro/diag-$(date +%s).jsonl ./MyApp > /var/log/aro/diag.log 2>&1 &
```

This launches the debugger detached, with a sample stride of 5000, recording everything to a timestamped JSONL, and logging output to a side file. The `nohup` lets you log out of the SSH session without killing the process.

From your laptop:

```bash
ssh -L 4711:localhost:4711 prod-host
```

Then connect VS Code or `nvim-dap` to `127.0.0.1:4711`. Set a breakpoint on the verb or location you want to inspect. The breakpoint fires on every match regardless of sampling. Inspect. Disconnect cleanly.

Pull the recording back:

```bash
scp prod-host:/var/log/aro/diag-*.jsonl /tmp/
aro debug --replay /tmp/diag-*.jsonl
```

You now have a local, scrubbable copy of the production state at the moment of interest. Iterate on the bug locally; the production process is no longer needed.

## 10.7 What's not yet here (v1 limits)

- **Unix-domain-socket attach.** `--dap-port` is TCP-only in v1. A `--dap-socket /var/run/aro.sock` flag is on the backlog; it would remove the port-allocation question.
- **WebSocket DAP for edge deploys.** Cloudflare Worker / Lambda runtimes do not host TCP listeners; a WebSocket transport that tunnels through the runtime's request path is the right shape, not yet implemented.
- **`aro debug --attach pid`.** Reaching into an *already running* process (one that wasn't started with `--dap-port`) requires a runtime interruption signal. Not in v1; tracked in #229 phase 5.

For now, "production attach" means "the production process was started with `--dap-port`." That is reasonable for services you control end-to-end; it is the wrong shape for serverless. The latter is on the roadmap.

---

**Next:** Appendix A — full command reference. Appendix B — glossary.
