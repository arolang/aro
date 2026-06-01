# Chapter 2: Getting Set Up

*"The fastest way to know the debugger works is to make it pause something you wrote."*

---

## 2.1 Install

The debugger ships inside the `aro` binary. There is no separate package. If you can run `aro --help` and see a `debug` subcommand listed, you are done with installation.

**macOS (Homebrew):**

```bash
brew tap arolang/aro
brew install aro
```

**Linux (binary release):**

Pick the artifact that matches your distribution from the [Releases page](https://github.com/arolang/aro/releases) and put `aro` on your `PATH`. The CI publishes signed `.deb` and `.rpm` flavors plus a portable tarball.

**From source:**

If you are reading this book because you are contributing to the debugger itself, the source path is:

```bash
git clone https://git.ausdertechnik.de/arolang/aro
cd aro
swift build -c release
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
`aro build` do not yet emit DWARF debug info — that's tracked
separately as issue #231. To debug, run from source.

Commands at a pause prompt:
  s, step            — advance one statement
  n, next            — advance one statement (alias for step)
  c, continue        — resume until next breakpoint or program end
  ...
```

If you see something materially different, the version on your machine is older than the one this book targets (`1.x`). Upgrade.

## 2.3 Smoke-test against HelloWorld

The repository's `Examples/HelloWorld` directory is the smallest meaningful ARO program. It is a single feature set with three statements:

```aro
(Application-Start: Entry Point) {
    Create the <greeting: String> with "Hello, ARO World!".
    Log <greeting> to the <console>.
    Return an <OK: status> for the <application>.
}
```

Run it under the debugger:

```bash
aro debug ./Examples/HelloWorld
```

You should see:

```
aro debug · 1.0.0 · HelloWorld
Use 'h' for help, 'q' to quit, 's' to step.

⏸  paused (entry) at main.aro:2 — Application-Start
   <Create> the <greeting: String> with the <_expression_> = "Hello, ARO World!".
(aro-dbg)
```

This is the *entry pause* — the very first checkpoint before any user code runs. If you got here, the debugger is installed correctly. Type `c` and press Enter to let the program finish:

```
(aro-dbg) c
[Application-Start] Hello, ARO World!

Program ended cleanly.
```

You now have a working debugger and a known-good project to practice on. Chapter 3 walks the rest of the session in detail.

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
