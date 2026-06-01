# Chapter 8: What lldb Can and Cannot See

*"The interpreter is the debugger. The native binary is a delivery format."*

---

## 8.1 Two paths, one source

ARO runs two ways. `aro run` walks the AST in an interpreter; `aro build` compiles to LLVM IR and links a native binary. Both consume the same `.aro` source. From the source author's perspective, the two are interchangeable; from the debugger's perspective, they are dramatically different.

`aro debug` drives the interpreter. Every feature in this book — statement-boundary stepping, the five breakpoint flavors, watches, record/replay, DAP — runs against the interpreter. If you want the full experience, debug from source.

The native binary is what you ship. It has function-level DWARF (chapter 8.3 below) so `lldb` can name your feature sets in a backtrace and read the source file each was defined in. That is the entire compiled-mode debugging story in v1; per-line breakpoints on `.aro` source inside a compiled binary are still a follow-up (issue #231).

The recommendation is the title of this chapter: **debug from source; ship the compile.**

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

## 8.3 What lldb does not see (yet)

Per-line breakpoints inside ARO source. If you try `breakpoint set --file main.aro --line 4`, `lldb` either refuses or sets a breakpoint that never resolves. The reason is technical: per-line breakpoints require LLVM `DILocation` metadata, which the codegen attaches via the LLVM IR builder's `setCurrentDebugLocation` call. The Swifty-LLVM dependency the compiler uses keeps the underlying builder handle internal; reaching it requires an upstream Swifty-LLVM change or a small bridge that we have not yet shipped.

Tracked in issue #231's second phase. Until it lands:

- **lldb backtraces work:** function names and source files are correct.
- **`image lookup -n`** finds feature sets by name.
- **`breakpoint set --name Application-Start`** by-function works.
- **`breakpoint set --file --line`** does not.

## 8.4 macOS-specific dSYM detail

On macOS, Mach-O leaves DWARF in the `.o` files by design and points to them via OSO stab entries in the linked binary. `dsymutil` reads OSO entries and constructs a `.dSYM` bundle that `lldb` consumes.

`aro build` produces a `.o` with valid DWARF and links the executable. In v1, Apple's `ld` does not record an OSO entry for our `.o` because the `.o` lacks the Apple-flavored debug stab structure `ld` expects. Result: `dsymutil` produces a `.dSYM` that has DWARF for the bundled Swift runtime but not for the ARO functions.

Workaround if you need symbols today: launch `lldb` and add the intermediate `.o` directly:

```bash
aro build Examples/HelloWorld --keep-intermediate
lldb Examples/HelloWorld/HelloWorld
(lldb) target symbols add Examples/HelloWorld/.build/HelloWorld.o
```

The `--keep-intermediate` flag tells `aro build` to leave the `.o` on disk. Without it the build cleans up.

Linux is different: ELF stores DWARF directly in the executable, no `.dSYM` indirection. Compiled-mode debugging should work end-to-end on Linux without the workaround. CI will confirm.

## 8.5 What this means for daily workflow

For most of your day:

```bash
aro debug ./MyApp
```

is the right tool. You get the full debugger surface this book describes.

When you specifically need to debug a *deployed* native binary — production crash, machine you can't run the interpreter on — `lldb` on the binary plus the source-name backtraces is what you have. It is not nothing; it's the same place a C codebase would be without `-g`.

When per-line breakpoints in compiled mode are required, the path is:

1. Reproduce the issue under `aro debug` from source.
2. Set the breakpoint there.
3. Fix and re-ship.

That is the recommended loop for v1, and it works because ARO's interpreter and native binary share the same `.aro` source — there is no "this only happens in compiled mode" bug class that lazy/eager differences from chapter 4 don't already cover. (The two runtimes share the lazy-future semantics, so a force-order quirk you'd hit in production also hits in the interpreter.)

## 8.6 What lands when #231 phase 2 ships

When the Swifty-LLVM upstream change (or our local bridge) opens up `LLVMSetCurrentDebugLocation2`, the compiler will emit per-instruction `!dbg` metadata. At that point:

- `lldb breakpoint set --file main.aro --line 5` will resolve in compiled binaries.
- VS Code / IntelliJ debug sessions launched against a compiled binary will hit source-level breakpoints.
- The macOS dSYM gap from chapter 8.4 will be addressed in the same MR (the underlying problem is shared).

Until then, this chapter is the honest answer to "can I debug a compiled binary?": yes for function names, no for per-line, and the recommendation is to use the interpreter.

---

**Next:** Chapter 9 introduces recording and replay — letting you debug a session that already finished by replaying the JSONL event log.
