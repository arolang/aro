# Chapter 8: What lldb Can and Cannot See

*"The interpreter is the debugger. The native binary is a delivery format."*

---

## 8.1 Two paths, one source

ARO runs two ways. `aro run` walks the AST in an interpreter; `aro build` compiles to LLVM IR and links a native binary. Both consume the same `.aro` source. From the source author's perspective, the two are interchangeable; from the debugger's perspective, they are dramatically different.

`aro debug` drives the interpreter. Every feature in this book — statement-boundary stepping, the six breakpoint flavors, watches, record/replay, DAP — runs against the interpreter. If you want the full experience, debug from source.

The native binary is what you ship. It carries real DWARF — a `DISubprogram` per feature set *and* a `DILocation` per statement — so `lldb` names your feature sets in a backtrace, reads the source file each was defined in, and resolves `breakpoint set --file main.aro --line 5` against your ARO source on both macOS and Linux (issue #231, both phases). What it does not carry is the rest of this book: watches, event and error-any breakpoints, record and replay, the causal call stack. Those live in the interpreter.

The recommendation is still the title of this chapter: **debug from source; ship the compile.** Not because the compiled binary is blind, but because the interpreter is where the debugger is.

## 8.2 What lldb does see in a compiled ARO binary

If you build `Examples/HelloWorld` with `aro build`:

```bash
aro build Examples/HelloWorld
file Examples/HelloWorld/HelloWorld
# Examples/HelloWorld/HelloWorld: Mach-O 64-bit executable arm64
```

You can run it directly: `./Examples/HelloWorld/HelloWorld`.

Under `lldb`, function-level DWARF gets you:

```text
(lldb) target create ./Examples/HelloWorld/HelloWorld
(lldb) image lookup -n aro_fs_application_start_entry_point
1 match found in HelloWorld:
        Address: HelloWorld[0x100001a00] (HelloWorld.__TEXT.__text + 0x...)
        Summary: Application-Start
         Module: file = "HelloWorld", arch = "arm64"
         Symbol: id = ..., range = [0x100001a00-0x100001da0), name = "Application-Start",
                  mangled = "aro_fs_application_start_entry_point"
```

The function's *name* and *source file* are visible. Backtraces during a crash report `Application-Start` instead of a raw address. That is the function-level DWARF working as designed.

## 8.3 Per-line breakpoints in a compiled binary

They work. The codegen sets the IR builder's current debug location before emitting the instructions for each statement, so every statement's instructions carry a `!dbg` reference back to `(file, line, column)` in the `.aro` source:

```text
(lldb) breakpoint set --file main.aro --line 5
Breakpoint 1: where = HelloWorld`aro_fs_application_start_entry_point + 468 at main.aro:5:5, address = 0x0000000100001cd4
```

All four of these hold in a compiled binary:

- **lldb backtraces work:** function names and source files are correct.
- **`image lookup -n`** finds feature sets by name.
- **`breakpoint set --name Application-Start`** by-function works.
- **`breakpoint set --file --line`** resolves against the `.aro` file.

What `lldb` still cannot show you is the ARO *bindings*. It sees the compiled program's machine state — the C-runtime calls each statement lowers to — not `<user>` and `<data>` as values. When you want to look at bindings, you want `aro debug` and the interpreter.

## 8.4 macOS-specific dSYM detail

On macOS, Mach-O leaves DWARF in the `.o` files by design and points to them via OSO stab entries in the linked binary. `lldb` follows those entries straight to the object (the "debug map"), and `dsymutil` reads the same entries to build a self-contained `.dSYM`.

Two things in `aro build` make that chain work, and each is easy to undo by accident. The compiler stamps a real absolute `DW_AT_comp_dir` on the compile unit, which is what persuades `ld64` to record an `N_OSO` stab for our object at all; and the object comes from `clang -c -g` on the IR rather than from `llc`, because `llc`'s output lacks the Apple-flavored stab structure `ld` expects. The link line carries `-g` for the same reason.

One wrinkle survives, and it is a housekeeping one: the debug map points at the intermediate `.o`, and `aro build` deletes that when the build finishes. A binary built without `--keep-intermediate` answers `Breakpoint 1: no locations (pending)` — which reads like missing debug info and is really a missing file. So for a debugging session, keep the object — or fold it into a `.dSYM`, which stands on its own afterwards (verified: `dsymutil` the binary, delete the `.o`, and the breakpoint still resolves):

```bash
aro build Examples/HelloWorld --keep-intermediate
dsymutil Examples/HelloWorld/HelloWorld     # optional; lldb then finds it by UUID
lldb Examples/HelloWorld/HelloWorld \
  -o 'breakpoint set --file main.aro --line 5' \
  -o run
```

Linux is simpler: ELF stores DWARF directly in the executable, no object-file indirection and no `.dSYM`, so a plain `aro build` is enough.

The whole chain — `!dbg` in the IR, `DW_TAG_subprogram` and a line table in the object, `N_OSO` on macOS, a resolving `breakpoint set --file --line` — is asserted end to end by `Tests/IntegrationTestsRunner/test-dwarf-debug-info.sh` in CI, which is why this section can promise it.


## 8.5 What this means for daily workflow

For most of your day:

```bash
aro debug ./MyApp
```

is the right tool. You get the full debugger surface this book describes.

When you specifically need to debug a *deployed* native binary — production crash, machine you can't run the interpreter on — `lldb` on the binary is a real debugger with real line numbers. You get backtraces naming your feature sets, breakpoints on `.aro` lines, and everything else lldb does with a C program compiled `-g`. What you do not get is ARO's own vocabulary: no `<user>` in the variables view, no watch list, no replay.

So the loop stays:

1. Reproduce the issue under `aro debug` from source.
2. Set the breakpoint there, where the bindings are legible.
3. Fix and re-ship.

That works for most bugs because the interpreter and the native binary share both the same `.aro` source *and* the same `ARORuntime` — the compiled program reaches it through the C ABI in `Sources/ARORuntime/Bridge/` rather than through a second implementation. The actions, the repositories, the HTTP server and the lazy-future semantics are all the same code, so a force-order quirk you hit in production hits in the interpreter too.

Two subsystems are the exception, and they are where a genuinely compiled-only bug lives. Expression evaluation has two implementations: the interpreter's `ExpressionEvaluator` and, for a serialized `when` or `while` condition, `evaluateExpressionJSON` in the bridge. Event dispatch likewise splits — typed Swift events through `EventBus` on one side, a `DomainEvent` string-plus-payload through the registration bridge on the other. Both are hand-maintained halves of one semantics, and *The Construction Studies* chapter 11 catalogues what has drifted across them before.

The practical consequence: when a program behaves differently under `aro run` and under its own binary, suspect a guard condition or an event payload first. If the source reproduces it, debug it from source. If only the binary reproduces it, you are probably standing on one of those two seams, and the line table plus `lldb` is what you have.

## 8.6 What is still missing

Not per-line breakpoints — those shipped. What's missing in compiled mode is everything above the line table:

- **Bindings.** lldb sees the machine state, not the symbol table. There is no compiled-mode equivalent of `p`.
- **The debugger's own breakpoint kinds.** Verb, event, error-any and logpoints are controller features; the controller runs in the interpreter.
- **Record and replay.** Same reason.

Whether a compiled binary should host a debug controller at all is a real design question rather than an oversight, and it is not answered yet. Meanwhile the honest answer to "can I debug a compiled binary?" is: yes for stepping and stack frames, no for ARO values — and if you want ARO values, use the interpreter.

---

**Next:** Chapter 9 introduces recording and replay — letting you debug a session that already finished by replaying the JSONL event log.
