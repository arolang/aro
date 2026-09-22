# Python plugins in a standalone binary

*Wiki page for GitLab #856. Paste into the GitHub wiki as `Static-Python.md`.*

`aro build --static` is the default and it promises one file you can copy
anywhere. A Python plugin ordinarily breaks that promise three times over: the
binary needs a CPython interpreter, a `libpython`, and the standard library, and
all three are resolved from the machine that ran the build.

So by default the build declines, and says what it would have depended on:

```
Error: Python plugin(s) 'markdown' cannot be embedded in a standalone binary.
  It needs a CPython interpreter and its standard library, which this build
  resolves from the machine it runs on:
    interpreter: /usr/bin/python3
    library:     /usr/lib/libpython3.12.dylib
    stdlib:      /usr/lib/python3.12
```

That is deliberate. A binary that looks standalone and fails at startup on
somebody else's machine is worse than a build that refuses.

## Building it anyway, properly

Give the build a CPython it can carry:

```bash
ARO_STATIC_PYTHON=/opt/cpython-static aro build ./MyApp
```

The binary then contains the interpreter and the standard library, and is a
single file in the sense `--static` always meant.

## What counts as a distribution it can carry

Two things, both required:

1. A **real** static `libpython<version>.a`.
2. Its standard library, at `<root>/lib/python<version>`, including `encodings`
   — the module `Py_Initialize` imports before it will run anything.

Where to get one:

- [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
  — prebuilt, per platform. Use a full build, not `install_only`; the latter
  ships only the dynamic library.
- CPython from source, configured `--disable-shared`.

### Why your existing Python almost certainly will not do

A stock python.org framework install ships this file:

```
$ ls -l .../lib/python3.12/config-3.12-darwin/libpython3.12.a
-> ../../../Python

$ file .../libpython3.12.a
Mach-O universal binary … dynamically linked shared library
```

It is named like a static archive and it is a symlink to the dynamic library.
Linking it produces a binary with a hard dependency on
`/Library/Frameworks/Python.framework` — precisely the failure this feature
exists to prevent, wearing a static name. Homebrew ships no static archive at
all, and neither do most Linux distribution packages.

The build therefore checks what the file *is*, by reading its first eight bytes
for `ar`'s `!<arch>` magic, and refuses a decoy with an explanation rather than
linking it.

## What gets carried, and what does not

Measured against CPython 3.12, whose full tree is about 1.3 GB:

| | |
|---|---|
| carried | 615 files, ~35 MB |
| CPython's own `test/` suite | excluded |
| `idlelib`, `tkinter`, `turtledemo` | excluded — need a display and Tcl/Tk |
| `__pycache__`, `.pyc` | excluded — regenerated, and stamped with build-machine paths |
| `site-packages` | **excluded deliberately** |

`site-packages` is the interesting one. Copying whatever happens to be installed
on the build machine is how a binary acquires dependencies nobody declared —
the same class of mistake as borrowing the machine's interpreter. A plugin's own
requirements are added explicitly from its `requirements.txt` instead.

Roughly 35 MB is a real cost on a binary that is otherwise about 34 MB for a
trivial application, so embedded Python is opt-in rather than automatic.

## Where the standard library lives at run time

Beside the executable, as `aro-python<version>/`:

```
myapp
aro-python3.12/
├── encodings/
├── json/
└── …
```

Not a temp directory. `/tmp` is frequently mounted `noexec`, which the stdlib's
C extension modules cannot survive, and a long-running service can have its temp
directory cleaned out from underneath it. The directory name carries the version
so two ARO binaries built against different Pythons can sit side by side.

## What still cannot be embedded

A plugin whose `requirements.txt` pulls a **native wheel** — numpy, pydantic-core,
anything with a compiled extension. Those are shared objects built for a
specific interpreter, and no amount of static linking folds them into an
executable. The build does not detect this and will happily produce a binary
that imports the module and fails; only pure-Python requirements survive the
trip. If your plugin needs a native wheel, the options are:

- `aro build --dynamic` — keep the dependency, and be told about it
- `aro run` — the interpreter, where Python plugins always work
- port the plugin to Swift, C or Rust, which do bake into the binary

## The escape hatch

When the build machine *is* the target machine — a CI job that builds and runs
in the same container, a binary you only ever run here — the dependency is
satisfied by construction and the refusal is just in the way:

```bash
ARO_ALLOW_EMBEDDED_PYTHON=1 aro build ./MyApp
```

It builds, and prints the same list of paths as a warning rather than an error.
Nothing about the binary changes: it still depends on that interpreter. The
variable only moves who is responsible for knowing that. ARO's own integration
test runner sets it, for exactly this reason.

## What the build prints when it works

```console
$ ARO_STATIC_PYTHON=/opt/cpython-static aro build ./MyApp
Embedding CPython 3.12 from /opt/cpython-static
  Python 3.12 standard library: 615 files, 35.1 MB
Built: ./MyApp/MyApp
```

If staging the standard library fails, the build fails with it. A binary with an
embedded interpreter and no standard library starts, imports nothing, and dies
on the first plugin call — there is no useful half-result to hand you.

## See also

- GitLab #608 — why a standalone binary refuses an embedded Python at all
- GitLab #616 — binary size, which this feature trades against
- `Proposals/ARO-0009-native-compilation.md` — what `aro build` produces
