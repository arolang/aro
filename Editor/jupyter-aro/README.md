# ARO Jupyter kernel

Run ARO in notebooks — JupyterLab, VS Code, DataSpell, or anything else that
speaks the Jupyter protocol. Cells share one session: define a feature set in
one cell, call it in the next.

```aro
(* cell 1 *)
(DoubleValue: Action takes <number>) {
    Extract the <n> from the <input: number>.
    Compute the <doubled> from <n> * 2.
    Return an <OK: status> with { doubled: <doubled> }.
}
```
```aro
(* cell 2 — the action defined above is callable here *)
Application.DoubleValue the <res> from 21.
Extract the <answer> from the <res: doubled>.
```
```
42
```

## Install

You need the `aro` binary and Python 3.9+.

### From a release (no checkout needed)

Every tagged release attaches a wheel, so installing the kernel does not
mean cloning the repository:

```bash
pip install https://github.com/arolang/aro/releases/latest/download/aro_kernel-py3-none-any.whl
python -m aro_kernel.install --user
```

### From a checkout

```bash
cd Editor/jupyter-aro
pip install -e .
python -m aro_kernel.install --user     # or --sys-prefix inside a virtualenv
```

If `aro` is not on your `PATH` — running against a checkout, say — point the
kernel at it before installing the spec, and the path is baked into the
kernelspec:

```bash
export ARO_KERNEL_ARO=/path/to/aro/.build/debug/aro
python -m aro_kernel.install --user
```

Check it registered:

```bash
jupyter kernelspec list      # should list "aro"
```

### VS Code

Install the Jupyter extension, open or create a `.ipynb`, and pick **ARO** from
the kernel picker (top right). Cells get ARO syntax highlighting if the
`Editor/vscode-aro` extension is installed — the kernel reports its language as
`aro`, which is the id that extension registers.

### DataSpell / PyCharm

DataSpell discovers kernelspecs from the Jupyter data directories, so
`--user` installs show up after a restart: **File → New → Jupyter Notebook**,
then choose **ARO** in the kernel selector. If it does not appear, check that
DataSpell's configured Jupyter environment is the one you installed into —
`jupyter kernelspec list` run from that interpreter must list `aro`.

**Why the kernel is not bundled with the IntelliJ plugin.** It would be the
nicer install — one Marketplace click — and the plugin
(`Editor/intellij-aro`) already depends only on `com.intellij.modules.platform`,
so it installs in DataSpell as well as IDEA. The kernel is the part that does
not travel:

- DataSpell runs notebooks through a **Jupyter server**, managed or external,
  and that server finds kernels through the ordinary kernelspec search path of
  *its own* Python environment. A plugin can write a `kernel.json` there, but
  it cannot make `aro_kernel` importable by an interpreter it does not own.
- The kernelspec's `argv` has to name a Python that can import the package and
  an `aro` binary that exists. Making that self-contained from a plugin means
  bundling a per-OS/arch `aro` plus a frozen Python — five platform payloads in
  a Marketplace artifact, to replace two `pip` lines.
- JetBrains' own notebook documentation is written around IPython
  ("IPyKernel supports only Python notebooks"), so how reliably a non-Python
  kernel is offered in the picker is worth confirming on a real DataSpell
  install before promising it in a plugin description.

The wheel on the release page is the supported route, and it is the one this
README documents. If a Marketplace install is wanted later, the tractable
version is a plugin that *detects* a missing kernelspec and offers to run the
two commands in the user's configured interpreter — not one that ships a
runtime.

### JupyterLab

```bash
pip install jupyterlab
jupyter lab
```

New → ARO.

## What works

| | |
|---|---|
| Session state | Variables and feature sets persist across cells |
| User-defined actions | `Application.<Name>` (ARO-0081) defined in one cell, called in another |
| Output | `Log` appears live while the cell runs, in order |
| Values | The last statement's result is displayed automatically |
| Tables | A list of records renders as an HTML table |
| Errors | ARO's own error text (ARO-0006), with the statement that caused it |
| Meta-commands | `:vars`, `:fs`, `:type`, `:help` — same set as `aro repl` |
| Completion | Tab completes actions, qualifiers, variables, feature sets |
| Inspection | Shift-Tab shows a variable's value or an action's role |

## Limits

**Event handlers do not fire.** A feature set with a `… Handler` activity is
registered but never dispatched, because the kernel does not run an event
loop. This matches `aro repl`; use `aro run` for event-driven applications.

**`Keepalive` is rejected.** It blocks until the process is signalled, which in
a cell means a spinner that never stops. Services started in an earlier
statement keep running without it. Set `ARO_REPL_ALLOW_BLOCKING=1` to override
and accept the consequences.

**Interrupt restarts the session.** A cell blocked inside the runtime cannot be
unwound, so "interrupt kernel" kills and replaces the ARO process. Variables
and definitions from earlier cells are gone; the kernel says so rather than
pretending otherwise.

## How it works

The kernel is a thin translation layer over `aro repl --json`, a
line-delimited JSON protocol on stdio:

```bash
$ echo '{"id":1,"type":"execute","code":"Compute the <n> from 2 + 40."}' | aro repl --json
{"protocol":1,"type":"ready","version":"0.11.1"}
{"display":{"application/json":42,"text/plain":"42"},"durationMs":3.02,"id":1,"status":"ok","type":"result"}
```

Requests are `execute`, `is_complete`, `complete`, `inspect`, `info`, `reset`,
and `shutdown`. Each gets exactly one `result` message with the same `id`,
preceded by any number of `stream` messages — and the server guarantees that
ordering, so a client never has to guess when a cell's output is finished.

Everything language-shaped happens on the ARO side (`Sources/AROCLI/REPL/`):
splitting a cell into units, deciding what to display, formatting errors. The
Python here does no ARO parsing at all, which is why a notebook and any other
client of the protocol behave identically.

See `Proposals/ARO-0091-jupyter-kernel.md` for the protocol specification.
