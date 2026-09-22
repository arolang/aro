<div align="center">

# ARO

**Action · Result · Object**

A language in which a business feature is the unit of code, and every line reads like the
sentence that asked for it.

[Website](https://arolang.github.io/aro/) · [Wiki](https://github.com/arolang/aro/wiki) ·
[Proposals](Proposals/) · [Examples](Examples/) · [Language Guide (PDF)](https://github.com/arolang/aro/releases/latest/download/ARO-Language-Guide.pdf)

</div>

---

## Part 1 — Using ARO

### Install

```bash
# macOS
brew tap arolang/aro && brew install aro

# Linux
curl -L https://github.com/arolang/aro/releases/latest/download/aro-linux-amd64.tar.gz | tar xz
sudo mv aro /usr/local/bin/ && sudo mv libARORuntime.a /usr/local/lib/

aro --version
```

The tap is `arolang/aro` (the repository `github.com/arolang/homebrew-aro`, which the release
pipeline updates). `brew install arolang/tap/aro` names a different tap that does not exist.

`aro run` needs nothing else. `aro build` additionally needs LLVM 20 and Clang.

### Hello

An ARO application is a **directory**, not a file.

```
HelloWorld/
└── main.aro
```

```aro
(Application-Start: Greeting) {
    Log "Hello, ARO." to the <console>.
    Return an <OK: status> for the <startup>.
}
```

```bash
aro run ./HelloWorld
```

### One sentence, one statement

Every statement has the same shape:

```
Action [article] <Result[: qualifier]> preposition [article] <Object[: qualifier]>.
```

The verb says what happens, the result is the name you get back, and the object is what it acts
on. Articles are optional and mean nothing; they are there so the line reads aloud.

```aro
Extract the <id> from the <pathParameters: id>.
Retrieve the <user> from the <user-repository> where <id> is <id>.
Compute the <initials: uppercase> from the <user: name>.
Return an <OK: status> with <user>.
```

There are 71 built-in actions and 130 verbs. `aro actions` prints the live table;
`aro actions Retrieve` explains one.

### Features, not functions

Code is organised into **feature sets** — a name, a business activity, and a body. Nothing calls a
feature set directly. The business activity decides what triggers it.

```aro
(* An HTTP route: the name matches an operationId in openapi.yaml *)
(createUser: User API) {
    Extract the <data> from the <request: body>.
    Create the <user> with <data>.
    Store the <user> into the <user-repository>.
    Emit a <UserCreated: event> with <user>.
    Return a <Created: status> with <user>.
}

(* An event handler: fires whenever that event is emitted *)
(Send Welcome Email: UserCreated Handler) {
    Extract the <address> from the <event: user.email>.
    Send the <welcome-email> to the <address>.
    Return an <OK: status> for the <notification>.
}
```

| If the business activity is… | it is triggered by |
|---|---|
| an `operationId` from `openapi.yaml` | an HTTP request on that route |
| `{EventName} Handler` | `Emit a <EventName: event>` |
| `{name}-repository Observer` | a write to that repository |
| `File Event Handler`, `Socket Event Handler`, `WebSocket Event Handler` | the corresponding service |
| `{field} StateObserver` | an `Accept`ed state transition |
| `Action` | `Application.<Name>` — the one form you call directly |
| `Application-Start`, `Application-End: Success`, `Application-End: Error` | the process lifecycle |

### Contract first

HTTP routes are not declared in ARO. They come from `openapi.yaml`, and feature sets are named
after the `operationId`. No contract means no server — no port is opened at all.

```yaml
paths:
  /users:
    post:
      operationId: createUser
      x-aro-max-body: 256KB
```

The contract is also the only place complex types are defined. ARO itself has String, Integer,
Float, Boolean and DateTime, plus `List` and `Map`; everything else comes from
`components.schemas`.

### The rules worth knowing on day one

**Values never change.** A name is bound once per feature set. Rebinding is a compile error, so
transformations produce new names:

```aro
Compute the <trimmed: trim> from the <raw>.
Compute the <upper: uppercase> from the <trimmed>.
```

**Only the happy path is written.** There is no `try`, no `catch`, no null check. When a statement
fails, the runtime reconstructs it as the error message:

```
Cannot retrieve the user from the user-repository where id = 530.
```

That message contains real values, which is exactly what makes it useful and exactly why this is
not suited to a public production API without care.

**Statements overlap by themselves.** Each one starts in source order; the program waits at the
first read of its result. Two independent requests in one feature set take as long as the slower
one. Effects — `Log`, `Store`, `Emit`, `Send`, `Return` — never move, so what you see is still in
the order you wrote. `ARO_NO_DEFER=1` turns it all off, which is the fastest way to find out
whether a bug is an ordering bug.

**Qualifiers are a closed set.** `<total: sum>`, `<name: uppercase>`, `<digest: sha256>` — and if
you invent one, `aro check` says so and names the closest match. `aro actions --qualifiers` lists
all 34.

### Running it

```bash
aro run ./MyApp              # interpret
aro check ./MyApp            # errors, warnings, per-route body analysis
aro test ./MyApp             # run the Given/When/Then feature sets
aro build ./MyApp            # compile to a native binary via LLVM
aro repl                     # interactive
aro kernel install           # register the Jupyter kernel
aro ui ./MyApp               # open Solaro, the ARO IDE
aro ask "add a delete route" # local-model assistant

echo 'Log "Hi" to the <console>.' | aro
```

Plugins in Swift, Rust, C, C++, Python or ARO itself live in `Plugins/` and add actions
(`Markdown.ToHTML the <html> from <source>.`) and qualifiers (`<x: markdown.render>`).

### Platform support

Most of ARO works everywhere. This table is the contract; please keep it current.

| | macOS | Linux | Windows |
|---|:---:|:---:|:---:|
| **Core** ||||
| `aro run`, `check`, `compile`, `test` | ✅ | ✅ | ✅ |
| `aro repl`, `repl --json` | ✅ | ✅ | ✅ ⁹ |
| `aro build` | ✅ | ✅ | ❌ ¹ |
| `aro build` with a Python plugin | ⚠️ ¹¹ | ⚠️ ¹¹ | ❌ ¹ |
| **Services** ||||
| HTTP server | ✅ | ✅ | ✅ ² |
| Streaming request bodies | ✅ | ✅ | ❌ ² |
| HTTP client, `Probe`, `Stream` | ✅ | ✅ | ❌ ³ |
| WebSocket | ✅ | ✅ | ❌ ² |
| Socket server | ✅ | ✅ | ✅ ² |
| Socket client (`Connect`) | ✅ | ✅ | ❌ ³ |
| File operations | ✅ | ✅ | ✅ |
| File monitoring | ✅ FSEvents | ✅ inotify | ⚠️ polling |
| `Exec` / `Shell` | ✅ | ✅ | ✅ ⁴ |
| Git actions (ARO-0080) | ✅ | ✅ | ❌ ⁵ |
| `.store` write-back | ✅ opt-in | ✅ opt-in | ✅ opt-in ⁶ |
| Terminal UI | ✅ | ✅ | ⚠️ ⁷ |
| Metrics | ✅ | ✅ | ❌ ⁸ |
| **Tools** ||||
| `aro lsp`, `mcp`, `ask`, `kernel` | ✅ | ✅ | ❌ ¹⁰ |
| Jupyter kernel | ✅ native | ✅ native | ⚠️ Python shim |
| Solaro IDE | ✅ | ❌ | ❌ |

¹ requires LLVM, not yet wired up on Windows — GitLab #613
² Windows uses FlyingFox rather than SwiftNIO: no body streaming, no WebSocket
³ GitLab #681
⁴ runs through `%COMSPEC%` (`cmd.exe /c`); a bare executable in the array
   form is found with `where.exe` rather than `/usr/bin/env` — GitLab #682
⁵ the module is compiled out — GitLab #683
⁶ opt-in is a `# aro-store: writable` marker in the file's leading comment
   block, since Windows has no other-write bit; ARO-0073 §3a — GitLab #684
⁷ Windows Terminal only, and hidden input echoes — GitLab #699
⁸ reports zeros rather than absence — GitLab #700
⁹ `Log` output is captured; stray `print`s from plugins are not
¹⁰ not registered as subcommands — GitLab #701
¹¹ needs `ARO_STATIC_PYTHON` pointing at an embeddable CPython; otherwise the
   build refuses rather than depend on the build machine's interpreter — GitLab #856

`MISSING.md` is the fuller list of what is absent, and why.

### Where to read next

| You want | Read |
|---|---|
| a tour | [Language Tour](https://github.com/arolang/aro/wiki/Language-Tour) |
| the reference | [Reference-Actions](https://github.com/arolang/aro/wiki/Reference-Actions), `aro actions` |
| the specification | [`Proposals/`](Proposals/) — start with 0001, 0004, 0005, then 0006 |
| worked code | [`Examples/`](Examples/) — 110 of them, all runnable |
| the long form | `Book/TheLanguageGuide` (55 chapters), `Book/TheEssentialPrimer` (one sitting) |
| how it is built | `Book/TheConstructionStudies`, `OVERVIEW.md` |

---

## Part 2 — Working on ARO

Whether you are bending ARO to your own needs or sending work back upstream, the shape is the
same.

### Build it

```bash
git clone https://github.com/arolang/aro.git
cd aro
swift build            # needs Swift 6.3, macOS 15+
swift test
```

The layout: `AROParser` (lexer, parser, AST, analysis), `ARORuntime` (interpreter and the
C-callable bridge), `AROCompiler` (LLVM code generation and linking), `AROCLI`, `AROLSP`,
`AROPackageManager`, `AROAsk`, `SOLARO`.

When you touch the runtime *and* want to test `aro build`, build both products — SwiftPM honours
only the last `--product`, and an installed `libARORuntime.a` otherwise wins over your worktree:

```bash
swift build --product ARORuntime && swift build --product aro
```

### Keep the layers in sync

The project has one rule that matters more than the rest. When two things disagree, this is the
order of truth:

```
Proposals/  →  Sources/  →  wiki, OVERVIEW.md  →  Website/  →  Book/
```

Change a layer, and every layer below it has to follow in the same change. If you add a platform
caveat, the Platform Support table above is part of that.

The order is a default, not a verdict. A lower layer is sometimes simply right — if the book
describes better behaviour than what ships, the fix is an issue against the code, not a worse
book.

### Sending a merge request

Bring three things. Written by hand or written with a model — nobody will ask, and vibe-coding is
welcome. What is not optional is the evidence.

**1. An example.** A directory under `Examples/` that exercises the thing, with a `test.hint` so
the integration harness runs it in both modes. If it cannot be an example, a test that reads like
one.

**2. Tests that pass.** `swift test` green, and `Tests/IntegrationTestsRunner/run-tests.pl` green.
A new action, qualifier or event kind needs a parity test too: `ActionRoleParityTests`,
`FrameworkVariableParityTests` and `CompiledBinaryOperatorParityTests` exist because the
interpreter and the compiled binary each keep their own copy of a catalog, and each pair has
drifted into a user-visible bug at least once.

**3. A motivation.** A short paragraph on what was not possible before, and why this shape rather
than another. "It seemed useful" does not survive contact with the source-of-truth rule; "the
crawler chapter needs four `Split` statements to do one match" does.

**Best of all: a proposal.** Anything that changes the language — syntax, a verb, a qualifier, an
event kind, a system object — belongs in `Proposals/` first, as `ARO-NNNN-short-title.md`. The
sequence is sparse on purpose, so take the next free number from `ls Proposals/` rather than
adding one to the highest. Follow the shape of an existing one: status, what problem it solves,
the grammar, the error messages, what is out of scope.

`Scripts/check-proposals.py` runs in CI and enforces that the number is unique, that the front
matter matches the filename, and that every `ARO-NNNN` reference anywhere in the repository
resolves.

Two conventions that trip people up:

- Cite issues as `GitLab #481`. The `ARO-` prefix means a proposal and nothing else.
- Never use `try?` without a comment saying why the fallback is acceptable. If it can lose data,
  write a warning to stderr as well.

### Finding something to do

- [`MISSING.md`](MISSING.md) — the gap inventory, each row linked to an issue.
- The [issue tracker](https://github.com/arolang/aro/issues) — `bug`,
  `enhancement`, `performance`, `refactoring`, `solaro`, `static-bin`, `training`.
- `aro check ./Examples/<anything>` — the warnings are noisy and often wrong, and fixing that is a
  well-defined job.

Bug reports are worth as much as patches, especially with a minimal `.aro` directory that
reproduces the problem and the output of both `aro run` and `aro build`.

---

## Part 3 — Why

Software teams have always had two artefacts that are supposed to describe the same thing: the
feature, as written by the people who wanted it, and the code, as written by the people who built
it. They start close and drift apart. Every practice we have — acceptance criteria, user stories,
BDD, living documentation — is an attempt to hold the two together, and every one of them works by
maintaining a second artefact alongside the first.

ARO starts from the observation that Feature-Driven Development, in 1997, already had the right
unit: a feature, expressed as `<action> the <result> <by|for|of|to> a(n) <object>`. Peter Coad and
Jeff De Luca used it to plan and track work. ARO's premise is that if the sentence is precise
enough to plan against, it is precise enough to execute — so make the sentence the program.

That single decision produces everything else:

**Statements read as sentences**, because the grammar is the feature template. `Retrieve the
<user> from the <user-repository> where <id> is <id>.` needs no translation to be understood by
whoever asked for it.

**Features are the unit of code**, so a feature set is triggered rather than called. There is no
call graph to hold in your head; there is a contract, some events, and the handlers that respond
to them. The parts that change together live together.

**Errors describe themselves.** If code is a sentence about intent, a failure is the same sentence
in the negative. `Cannot retrieve the user from the user-repository where id = 530.` is not a
message someone wrote — it is the statement that failed, with the values filled in. No error
strings to maintain, and none to fall out of date.

**Values do not change.** A name bound once per feature set means a statement can be read in
isolation, which is what lets the runtime start work early and wait only at the first read — and
what lets a diff of two revisions show you the feature graph rather than the lines.

**The contract is outside the code.** Routes and types come from `openapi.yaml`, so the API is
described once, in the format the rest of the world already reads, and the code cannot drift from
it.

And there is a newer reason. A language whose grammar is this regular, whose vocabulary is closed,
and whose checker is this strict is unusually easy for a model to write correctly — and unusually
easy to *verify*. `aro check` is a real oracle: it knows every preposition and every qualifier,
and it says which one you meant instead. That is why ARO ships with a local model (`aro ask`)
trained on its own corpus, and why the training pipeline grades on the checker rather than on a
similarity score. Natural language in, a valid feature out, with a machine in the middle that can
prove the result parses.

ARO is a research language with production ambitions and a small team. It is not finished — the
inventory of what is missing is in `MISSING.md`, and it is long on purpose. But the core bet has
held: when the sentence is the program, the description and the implementation cannot drift,
because there is only one of them.

---

<div align="center">

MIT licensed · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) · [`SECURITY.md`](SECURITY.md)

*Making business features executable.*

</div>
