# SOLARO developer troubleshooting

Rough edges you hit while **building and iterating on SOLARO itself** —
not bugs in the app, but friction in the macOS dev loop that every new
contributor (or agent rebuilding the IDE) otherwise re-discovers from
scratch. Each entry is Symptom / Cause / Fix with a runnable snippet.

When you fix one of these in an MR, link this file so the next person
finds the workaround instead of re-deriving it.

See also [`ARCHITECTURE.md`](./ARCHITECTURE.md) for the codebase map.

> Paths below assume a debug build (`swift build`). For release builds
> swap `debug` → `release` and `SolaroApp` bundles accordingly.

---

## 1. "Code Signature Invalid" after copying into the bundle

**Symptom.** After `cp`-ing a freshly built binary (the `aro` CLI, a
plugin dylib, or the app executable) into `.build/Solaro.app`, launching
the app fails with a *Code Signature Invalid* / *killed: 9* error, or
Gatekeeper refuses it outright.

**Cause.** macOS records a code signature over the bundle's contents. Any
manual `cp` into `Contents/MacOS/` (or `Contents/…`) invalidates that
signature — the on-disk bytes no longer match what was signed. SwiftPM
doesn't re-sign on a bare copy.

**Fix.** Re-sign the modified binary ad-hoc (`-`) after the copy:

```bash
codesign --force --sign - .build/Solaro.app/Contents/MacOS/Solaro
```

Re-sign whichever file you touched (the `aro` CLI or a plugin dylib copied
next to it takes the same command with its own path). #288 covers the
packaged case; this is the fix for the common manual-copy loop.

---

## 2. Stale `.o` — "Compiling File.swift" but nothing changes

**Symptom.** You edit a file, rebuild, and SwiftPM prints
`Compiling File.swift` — but the behaviour doesn't change, as if the edit
never landed.

**Cause.** SwiftPM's incremental build tracking keys off file timestamps
and content hashes. A `touch`-only edit (or a tool that rewrites a file
with an unchanged mtime) can leave the cached `.o` newer than SwiftPM
thinks the source is, so it relinks the *old* object.

**Fix.** Delete the stale object for that file and rebuild:

```bash
rm .build/debug/SOLARO.build/File.swift.o
swift build --target SOLARO
```

Nuclear option if several files are stale: `rm -rf .build/debug/SOLARO.build`
(forces a full recompile of the target, not the whole graph).

---

## 3. Settings window restored instead of the main window

**Symptom.** You launch a fresh build and macOS restores a lone
**Settings** window (or some other secondary window) instead of the main
workspace — the app looks broken on startup.

**Cause.** macOS persists per-app *Saved Application State* and replays the
window layout from the previous session on launch. A build that crashed or
was killed while Settings was frontmost gets that state restored.

**Fix.** Clear the saved state for SOLARO's bundle id:

```bash
rm -rf ~/Library/Saved\ Application\ State/com.arolang.SOLARO.savedState
```

Relaunch — the app opens to the normal Welcome / workspace window.

---

## 4. `open -a` launches the running instance, not your new build

**Symptom.** You rebuild, run
`open -a .build/Solaro.app /path/to/project`, and your changes aren't
there — you're looking at the previous build.

**Cause.** Launch Services routes `open -a` to an *already-running*
instance of the same bundle id if one exists, forwarding the document to
it rather than starting the new binary on disk.

**Fix.** Kill the running instance first, then open:

```bash
pgrep Solaro | xargs kill -9 2>/dev/null
open -a .build/Solaro.app /path/to/project
```

(See item 6 for why `pgrep Solaro` sometimes misses processes — prefer the
`pgrep -f` form when in doubt.)

---

## 5. Stale `.build/release/aro` shadows `.build/debug/aro`

**Symptom.** SOLARO (or a script) resolves the `aro` CLI and gets an old
build — a fix you just made to the runtime isn't reflected at run time.

**Cause.** The binary resolver walks candidate locations and, before the
fix in #287 / commit `56595328`, could return `.build/release/aro` ahead
of the newer `.build/debug/aro` you were actually iterating on.

**Fix.** The resolver order is fixed in `56595328`, but if you have both
builds and want to be sure the debug one wins, delete the older artefact:

```bash
rm -f .build/release/aro        # or the debug one, whichever is stale
```

Alternatively pin the binary explicitly in Settings → Backends
(`SOLARO_ARO` override) so resolution order never matters.

---

## 6. Multiple SOLARO processes accumulate

**Symptom.** After several dev launches, several SOLARO processes are alive
at once (the launcher plus one or more `.app` instances), fighting over
windows, ports, or the XPC service.

**Cause.** Both the `solaro` launcher and the `Solaro.app` bundle can spawn
a process, and a killed-but-not-reaped instance can linger. `pgrep Solaro`
matches only the process *name* — it misses the launcher and helpers whose
argv[0] differs.

**Fix.** Match the full command line with `pgrep -f`:

```bash
pgrep -f Solaro | xargs kill -9 2>/dev/null
```

Use this (not `pgrep Solaro`) before any "start a clean instance" step so
no stale process survives.

---

## Quick reference

```bash
# Re-sign after a manual copy into the bundle
codesign --force --sign - .build/Solaro.app/Contents/MacOS/Solaro

# Drop a stale object file
rm .build/debug/SOLARO.build/File.swift.o

# Reset saved window state
rm -rf ~/Library/Saved\ Application\ State/com.arolang.SOLARO.savedState

# Kill every SOLARO process (launcher + app + helpers), then relaunch
pgrep -f Solaro | xargs kill -9 2>/dev/null
open -a .build/Solaro.app /path/to/project
```
