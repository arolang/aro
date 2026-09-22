# Chapter 2: Getting Set Up

*"The fastest way to know the debugger works is to make it pause something you wrote."*

---

## 2.1 Install

The debugger ships inside the `aro` binary. There is no separate package. If you can run `aro --help` and see a `debug` subcommand listed, you are done with installation.

<!-- ARO:INCLUDE Install.md -->
*See [the shared installation instructions](../Install.md).*
<!-- /ARO:INCLUDE -->

If you are reading this book because you are contributing to the debugger itself, build from source and check the subcommand directly:

```bash
./.build/release/aro --help | grep debug
```

You should see this line:

```
debug                   Step-debug an ARO application
```

If you do not, you are looking at an older build that predates the debugger. Check that you are on `main` and that the build finished without errors.

## 2.2 Verify

The cleanest sanity check is the help text. It documents the surface this book describes.

```bash
aro debug --help
```

The output begins:

```
OVERVIEW: Step-debug an ARO application

Pauses execution at every ARO statement and accepts a small set of
REPL commands over stdin. Issue #229 Phase 1.

Note: this driver runs the program through the ARO interpreter
(the same path as `aro run`). Compiled binaries produced by
`aro build` now emit DWARF debug info and support source-level
breakpoints in lldb on both macOS and Linux — build the app,
then `lldb <binary>` and e.g. `breakpoint set --file main.aro
--line 5` (issue #231).

Commands at a pause prompt:
  s, step            — advance one statement
  n, next            — advance one statement (alias for step)
  c, continue        — resume until next breakpoint or program end
  ...
```

If you see something materially different, the version on your machine is older than the one this book targets (`1.x`). Upgrade.

## 2.3 Smoke-test against HelloWorld

The repository's `Examples/HelloWorld` directory is the smallest meaningful ARO program. It is a single feature set with three statements — shown here with its line numbers, because the debugger will quote them back at you:

```aro
1  (* HelloWorld - The simplest ARO application *)
2
3  (Application-Start: Entry Point) {
4      Create the <greeting: String> with "Hello, ARO World!".
5      Log <greeting> to the <console>.
6      Return an <OK: status> for the <application>.
7  }
```

Run it under the debugger:

```bash
aro debug ./Examples/HelloWorld
```

You should see:

```
aro debug · 1.0.0 · HelloWorld
Use 'h' for help, 'q' to quit, 's' to step.
Metrics socket: /tmp/aro-metrics-8691.sock

⏸  paused (entry) at main.aro:4 — Application-Start
   <Create> the <greeting: String> with the <_expression_> = "Hello, ARO World!".
(aro-dbg)
```

(The version in the banner is whatever binary you are running; a source build says `dev`. The metrics-socket line is the runtime announcing its Prometheus scrape endpoint — every `aro` process prints it, debugger or not.)

This is the *entry pause* — the very first checkpoint before any user code runs. If you got here, the debugger is installed correctly. Type `c` and press Enter to let the program finish:

```
(aro-dbg) c
Hello, ARO World!

Program ended cleanly.
```

You now have a working debugger and a known-good project to practice on. Chapter 3 walks the rest of the session in detail.

## 2.3b Debugging a compiled binary with lldb

`aro debug` steps the interpreter. When you want to debug the *native* binary that `aro build` produces, use `lldb` directly — compiled binaries carry per-statement DWARF (issue #231), so lldb resolves breakpoints against your `.aro` files by name and line on both macOS and Linux.

On macOS there is one flag you must not forget:

```bash
aro build ./Examples/HelloWorld --keep-intermediate
lldb ./Examples/HelloWorld/HelloWorld \
  -o 'breakpoint set --file main.aro --line 5' \
  -o run
```

```
Breakpoint 1: where = HelloWorld`aro_fs_application_start_entry_point + 468 at main.aro:5:5, address = 0x0000000100001cd4
```

The source line tables live in the object file's `__DWARF` segment and the linked binary only points at them, so lldb needs the `.o` still on disk — and a plain `aro build` deletes it. Without `--keep-intermediate` the same command answers `Breakpoint 1: no locations (pending)`, which looks like missing debug info and is really a missing file. Run `dsymutil` on the binary once and the `.dSYM` it produces stands alone; you can delete the object then. Chapter 8.4 has the whole story. Linux needs none of this: the DWARF is in the executable.

## 2.4 Where the binary looks for things

Three files matter:

- The application directory you pass on the command line (`./Examples/HelloWorld`)
- `openapi.yaml` inside that directory, if present (HTTP routes)
- `Plugins/` inside that directory, if present (loaded automatically)

The debugger does not consult anything outside the project except the system `aro` binary itself. There is no `~/.arodebugrc`, no project-level `debug.yaml`, no global breakpoint store. The state you see is the state you typed.

This is intentional. If a colleague asks "how did you set that breakpoint?", the answer is in your scrollback, not in a config file they need to clone.

## 2.5 Where the docs live

This book is one of two places to look:

1. **`aro debug --help`** — every flag, every pause command, the current version.
2. **This guide** — concepts, workflows, war stories.

The help text always tracks the binary. This book tracks a specific version (see the title page). If a flag in the help text is missing here, the help text is right. If this book describes a flag the help text doesn't have, you are on an older binary. The book never lies about features the binary doesn't yet have — when something is deferred to a follow-up, it says so and points at the issue.

---

**Next:** Chapter 3 walks the full HelloWorld session step by step — set a breakpoint, inspect a binding, continue, exit cleanly.
