# Chapter 1: Design Philosophy

## The Constraint Hypothesis

ARO operates on a hypothesis that runs counter to mainstream language design: **expressiveness and predictability are inversely correlated**. General-purpose languages maximize expressiveness — you can write anything. ARO minimizes it — you can write only certain things in certain ways.

<svg viewBox="0 0 600 400" xmlns="http://www.w3.org/2000/svg">
  <style>
    .axis { stroke: #333; stroke-width: 2; }
    .label { font-family: monospace; font-size: 12px; fill: #333; }
    .title { font-family: monospace; font-size: 14px; fill: #333; font-weight: bold; }
    .dot { stroke: #333; stroke-width: 1; }
    .curve { fill: none; stroke: #666; stroke-width: 2; stroke-dasharray: 5,5; }
  </style>

  <!-- Axes -->
  <line x1="80" y1="320" x2="550" y2="320" class="axis"/>
  <line x1="80" y1="320" x2="80" y2="50" class="axis"/>

  <!-- Axis labels -->
  <text x="300" y="360" class="title" text-anchor="middle">Expressiveness</text>
  <text x="30" y="185" class="title" text-anchor="middle" transform="rotate(-90, 30, 185)">Predictability</text>

  <!-- Trade-off curve -->
  <path d="M 100 80 Q 250 90 350 150 Q 450 220 530 300" class="curve"/>

  <!-- Language positions -->
  <!-- ARO - high predictability, low expressiveness -->
  <circle cx="120" cy="100" r="8" fill="#4a9" class="dot"/>
  <text x="135" y="105" class="label">ARO</text>

  <!-- SQL - high predictability, low expressiveness -->
  <circle cx="150" cy="95" r="8" fill="#4a9" class="dot"/>
  <text x="165" y="100" class="label">SQL</text>

  <!-- Make - medium-high predictability -->
  <circle cx="200" cy="110" r="8" fill="#4a9" class="dot"/>
  <text x="215" y="115" class="label">Make</text>

  <!-- Terraform - medium predictability -->
  <circle cx="280" cy="130" r="8" fill="#69a" class="dot"/>
  <text x="295" y="135" class="label">Terraform</text>

  <!-- Go - medium -->
  <circle cx="350" cy="170" r="8" fill="#69a" class="dot"/>
  <text x="365" y="175" class="label">Go</text>

  <!-- Python - lower predictability, high expressiveness -->
  <circle cx="420" cy="220" r="8" fill="#a66" class="dot"/>
  <text x="435" y="225" class="label">Python</text>

  <!-- JavaScript - low predictability, high expressiveness -->
  <circle cx="480" cy="260" r="8" fill="#a66" class="dot"/>
  <text x="420" y="275" class="label">JavaScript</text>

  <!-- Lisp - lowest predictability, highest expressiveness -->
  <circle cx="520" cy="295" r="8" fill="#a66" class="dot"/>
  <text x="500" y="320" class="label">Lisp</text>

  <!-- Legend -->
  <rect x="400" y="60" width="140" height="70" fill="none" stroke="#ccc"/>
  <circle cx="415" cy="80" r="5" fill="#4a9"/>
  <text x="425" y="84" class="label">Constrained DSL</text>
  <circle cx="415" cy="100" r="5" fill="#69a"/>
  <text x="425" y="104" class="label">General-purpose</text>
  <circle cx="415" cy="120" r="5" fill="#a66"/>
  <text x="425" y="124" class="label">Dynamic/flexible</text>
</svg>

**Figure 1.1**: The expressiveness-predictability trade-off. Languages cluster along an inverse relationship. ARO occupies the high-predictability, low-expressiveness corner deliberately.

This is not a universal truth — it is a design bet. The bet is that for certain problem domains, the benefits of predictability (uniform tooling, auditable code, consistent execution) outweigh the costs of limited expressiveness.

### What "Constraint" Means Architecturally

In a general-purpose language, AST node types proliferate. Python's AST has over 40 statement types and 20+ expression types. Each new construct adds parsing rules, semantic analysis passes, and code generation cases.

ARO has eight statement types:

1. `AROStatement` — the core action-result-object form
2. `PublishStatement` — variable export across feature sets
3. `ForEachLoop` — collection iteration
4. `RequireStatement` — dependency declaration
5. `MatchStatement` — pattern matching
6. `RangeLoop` — numeric range iteration
7. `WhileLoop` — condition-based iteration
8. `BreakStatement` — loop exit

**Lifecycle feature sets** (`Application-Start`, `Application-End: Success`, `Application-End: Error`) are not special statement types. They are regular feature sets distinguished by naming convention. The runtime treats them specially based on their business activity names.

Here's why that's clever: every new statement type would add cases everywhere — in the parser, the semantic analyzer, the code generator, the interpreter, the LLVM backend, and every tool that reads an AST. Eight types means all of those places stay small and focused. The constraint propagates as a simplification through the entire codebase.

---

## Data Flow as Organizing Principle

We classify every action by its data flow direction. This is not just documentation — it is enforced at the type level. Every action implementation declares its role, and the runtime uses that to decide what bridge functions to call, what prepositions are valid, and what optimizations are safe.

| Role | Direction | Examples |
|------|-----------|---------|
| `request` | External → Internal | Extract, Retrieve, Fetch, Read |
| `own` | Internal → Internal | Compute, Validate, Compare, Create, Transform |
| `response` | Internal → External | Return, Throw |
| `export` | Internal → Persistent / Global | Publish, Store, Log, Send, Emit |

<svg viewBox="0 0 700 350" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { fill: #f5f5f5; stroke: #333; stroke-width: 2; }
    .arrow { fill: none; stroke: #333; stroke-width: 2; marker-end: url(#arrowhead); }
    .label { font-family: monospace; font-size: 11px; fill: #333; }
    .title { font-family: monospace; font-size: 13px; fill: #333; font-weight: bold; }
    .role { font-family: monospace; font-size: 10px; fill: #666; }
    .external { fill: #e8f4e8; }
    .internal { fill: #e8e8f4; }
  </style>

  <defs>
    <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#333"/>
    </marker>
  </defs>

  <!-- External Sources -->
  <rect x="30" y="80" width="120" height="180" rx="5" class="box external"/>
  <text x="90" y="105" class="title" text-anchor="middle">External</text>
  <text x="90" y="120" class="title" text-anchor="middle">Sources</text>
  <text x="90" y="150" class="label" text-anchor="middle">HTTP requests</text>
  <text x="90" y="165" class="label" text-anchor="middle">Files</text>
  <text x="90" y="180" class="label" text-anchor="middle">Sockets</text>
  <text x="90" y="195" class="label" text-anchor="middle">Repositories</text>
  <text x="90" y="210" class="label" text-anchor="middle">Environment</text>

  <!-- REQUEST arrow -->
  <line x1="150" y1="140" x2="210" y2="140" class="arrow"/>
  <text x="180" y="130" class="role" text-anchor="middle">REQUEST</text>
  <text x="180" y="155" class="label" text-anchor="middle">Extract</text>
  <text x="180" y="168" class="label" text-anchor="middle">Retrieve</text>
  <text x="180" y="181" class="label" text-anchor="middle">Read</text>

  <!-- Internal State -->
  <rect x="220" y="80" width="140" height="180" rx="5" class="box internal"/>
  <text x="290" y="105" class="title" text-anchor="middle">Internal</text>
  <text x="290" y="120" class="title" text-anchor="middle">State</text>
  <text x="290" y="150" class="label" text-anchor="middle">Variables</text>
  <text x="290" y="165" class="label" text-anchor="middle">Computed values</text>
  <text x="290" y="180" class="label" text-anchor="middle">Transformed data</text>
  <text x="290" y="195" class="label" text-anchor="middle">Created objects</text>

  <!-- OWN loop -->
  <path d="M 290 260 C 290 290 290 290 290 290 C 330 290 330 260 330 260" fill="none" stroke="#333" stroke-width="2"/>
  <polygon points="330,260 325,270 335,270" fill="#333"/>
  <text x="310" y="305" class="role" text-anchor="middle">OWN</text>
  <text x="260" y="320" class="label">Compute, Validate, Transform, Create</text>

  <!-- RESPONSE arrow -->
  <line x1="360" y1="140" x2="420" y2="140" class="arrow"/>
  <text x="390" y="130" class="role" text-anchor="middle">RESPONSE</text>
  <text x="390" y="155" class="label" text-anchor="middle">Return</text>
  <text x="390" y="168" class="label" text-anchor="middle">Throw</text>
  <text x="390" y="181" class="label" text-anchor="middle">Log</text>

  <!-- External Targets -->
  <rect x="430" y="80" width="120" height="180" rx="5" class="box external"/>
  <text x="490" y="105" class="title" text-anchor="middle">External</text>
  <text x="490" y="120" class="title" text-anchor="middle">Targets</text>
  <text x="490" y="150" class="label" text-anchor="middle">HTTP responses</text>
  <text x="490" y="165" class="label" text-anchor="middle">Console output</text>
  <text x="490" y="180" class="label" text-anchor="middle">Sockets</text>
  <text x="490" y="195" class="label" text-anchor="middle">Notifications</text>

  <!-- EXPORT arrow (downward from internal) -->
  <line x1="290" y1="260" x2="290" y2="320" class="arrow" style="marker-end: none;"/>
  <line x1="290" y1="320" x2="600" y2="320" class="arrow" style="marker-end: none;"/>
  <line x1="600" y1="320" x2="600" y2="180" class="arrow"/>
  <text x="445" y="340" class="role" text-anchor="middle">EXPORT: Publish, Store, Emit</text>

  <!-- Persistent Storage -->
  <rect x="560" y="80" width="100" height="100" rx="5" class="box"/>
  <text x="610" y="105" class="title" text-anchor="middle">Persistent</text>
  <text x="610" y="120" class="title" text-anchor="middle">Storage</text>
  <text x="610" y="145" class="label" text-anchor="middle">Repositories</text>
  <text x="610" y="160" class="label" text-anchor="middle">Events</text>
</svg>

**Figure 1.2**: Action role data flow. Every action in ARO belongs to exactly one of four roles, determining where data flows.

### Why Roles Matter

The role classification pays off in several concrete ways:

- **Preposition validation**: Each role has valid prepositions. REQUEST actions use `from` (pulling data in from somewhere); RESPONSE actions use `to` or `for` (sending data out somewhere). A REQUEST action with `to` is suspicious, and we can flag it.
- **Static analysis**: The semantic analyzer can verify data flow direction from the role alone, without reading the implementation.
- **Code generation**: The LLVM backend knows which C bridge functions to call based on role, without inspecting the action further.
- **Runtime optimization**: REQUEST actions may be cached; EXPORT actions may be batched.

---

## Immutability by Default

Variables in ARO cannot be rebound. This is not a convention — it is enforced at two layers.

The **semantic analyzer** checks at compile time: if you try to bind a name that already exists in the symbol table, it flags it as an error. The **runtime** has a second safety net that catches anything the analyzer missed. In practice the runtime check should never fire — if it does, we have a compiler bug.

The escape hatch is the `_` prefix, reserved for framework-internal variables like `_expression_` and `_with_`. Those are exempt from immutability checks because the runtime needs to shuttle values between pipeline stages.

Here's why this is worth the pain:

- **No aliasing problems**: If `x` cannot change, you never need to wonder whether `y` also points to the same value that just mutated.
- **Parallel safety**: Immutable bindings are inherently thread-safe. The `Sendable` conformance of `SymbolTable` relies entirely on this property.
- **Simpler code generation**: The LLVM backend does not need to track which variables might be modified later. Every binding is a one-time write.
- **Predictable debugging**: The value of a variable is always the value it was given when first bound. No surprises mid-execution.

The new-name pattern is the idiomatic workaround when you need multiple transformations of the same data:

```aro
Compute the <name-upper: uppercase> from the <name>.
Compute the <name-trimmed: trim> from the <name-upper>.
```

Each step gets a new name. Verbose, yes — but you can read the entire data flow top to bottom without tracking mutations.

---

## The "Code is the Error Message" Philosophy

ARO's error handling is unusual: there isn't any. Programmers write only the successful case. When something goes wrong, the runtime generates an error message from the source code itself.

```aro
Retrieve the <user> from the <user-repository> where id = <id>.
```

If the retrieval fails, the runtime produces:

```
Cannot retrieve the user from the user-repository where id = 530.
```

The number `530` is not hard-coded anywhere — it is the resolved value of `<id>` at the time of failure, substituted directly into the message. The statement you wrote becomes the error message, with variables replaced by their actual values.

This is not a debugging convenience bolted on afterwards. It is a fundamental design principle that shapes what the language can and cannot express.

The implementation is straightforward: when an action throws, the runtime walks the AST node for that statement, reconstructs the natural-language form using the action verb, result name, preposition, and object name, then substitutes any variable references with their resolved values from the current context. The source code and the error message are the same sentence, one with names and one with values.

### Trade-offs

**Gained:**

- Zero error-handling code in ARO programs
- Error messages always match the code — they cannot drift
- Full debugging context in every error, no log-hunting required

**Lost:**

- No custom error messages (without explicitly using `Throw`)
- Security-sensitive information may leak in error output
- No programmatic error recovery

The security issue is real and worth emphasizing. Error messages expose variable values, repository names, and internal state. ARO is explicitly not designed for production systems handling sensitive data.

---

## Trade-off Analysis

### What We Gave Up

| Lost Feature | Why It Was Removed | Consequence |
|--------------|-------------------|-------------|
| General loops | Encourage declarative thinking | Use `for each` or custom actions |
| Arbitrary functions | Feature sets are not functions | Cannot factor common code easily |
| Complex conditionals | Guards and match instead | Nested logic requires workarounds |
| Custom operators | Fixed expression grammar | Cannot extend syntax |
| Exception handling | Happy path only | Errors terminate execution |
| Type annotations | OpenAPI schemas only | Limited static typing |

### What We Gained

| Gained Property | How It Was Achieved | Benefit |
|-----------------|---------------------|---------|
| Uniform AST | Eight statement types | Simple tooling |
| Predictable execution | Linear statement flow | Easy debugging |
| Auditable code | One way to do things | Code review is fast |
| Consistent error messages | Code-derived errors | Debugging by reading |
| Safe concurrency | Immutable bindings | No race conditions in user code |

### The Central Trade-off

<svg viewBox="0 0 600 300" xmlns="http://www.w3.org/2000/svg">
  <style>
    .box { stroke: #333; stroke-width: 2; }
    .arrow { fill: none; stroke: #333; stroke-width: 2; marker-end: url(#arrowhead2); }
    .label { font-family: monospace; font-size: 11px; fill: #333; }
    .title { font-family: monospace; font-size: 13px; fill: #333; font-weight: bold; }
  </style>

  <defs>
    <marker id="arrowhead2" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#333"/>
    </marker>
  </defs>

  <!-- Constraint -->
  <rect x="50" y="100" width="150" height="80" rx="5" class="box" fill="#fee"/>
  <text x="125" y="130" class="title" text-anchor="middle">CONSTRAINT</text>
  <text x="125" y="150" class="label" text-anchor="middle">Limited syntax</text>
  <text x="125" y="165" class="label" text-anchor="middle">Fixed vocabulary</text>

  <!-- Arrow -->
  <line x1="200" y1="140" x2="280" y2="140" class="arrow"/>

  <!-- Uniformity -->
  <rect x="290" y="100" width="150" height="80" rx="5" class="box" fill="#efe"/>
  <text x="365" y="130" class="title" text-anchor="middle">UNIFORMITY</text>
  <text x="365" y="150" class="label" text-anchor="middle">Consistent structure</text>
  <text x="365" y="165" class="label" text-anchor="middle">Predictable patterns</text>

  <!-- Escape Hatches -->
  <rect x="50" y="200" width="150" height="60" rx="5" class="box" fill="#eef"/>
  <text x="125" y="220" class="title" text-anchor="middle">ESCAPE HATCH</text>
  <text x="125" y="238" class="label" text-anchor="middle">Plugins (Swift/Rust/C/Python)</text>
  <text x="125" y="253" class="label" text-anchor="middle">Custom actions (Swift)</text>

  <!-- Arrow from escape to constraint -->
  <path d="M 125 200 L 125 180" class="arrow" style="marker-end: url(#arrowhead2);"/>
  <text x="140" y="193" class="label">extends</text>

  <!-- Cost box -->
  <rect x="290" y="200" width="150" height="60" rx="5" class="box" fill="#ffe"/>
  <text x="365" y="220" class="title" text-anchor="middle">COST</text>
  <text x="365" y="238" class="label" text-anchor="middle">Swift actions need recompile</text>
  <text x="365" y="253" class="label" text-anchor="middle">Plugins need build step</text>
</svg>

**Figure 1.3**: The constraint-uniformity trade-off with escape hatch.

The escape hatch is essential. Without it, ARO would be too limited for real use. We offer two levels:

**Plugins** (Swift, Rust, C, Python) are loaded as dynamic libraries or subprocesses. They can add new actions and qualifiers without touching the ARO runtime itself. They are namespaced via a `handler:` field in `plugin.yaml` — so a `collections` handler exposes qualifiers as `collections.pick-random`, `collections.shuffle`, and so on. This is the preferred escape mechanism: write your plugin, drop it in `Plugins/`, and the runtime finds it automatically.

**Custom actions in Swift** are compiled directly into the runtime. More tightly integrated, but requires recompiling the ARO binary. Useful for actions that need deep access to the execution engine.

With these escape hatches, the constraint becomes a useful default rather than a prison. You stay within ARO's vocabulary unless you genuinely need to leave — and when you do, the plugin system makes the exit clean.

---

## Chapter Summary

ARO's design philosophy rests on four pillars:

1. **Constraint over expressiveness**: Fewer constructs means simpler implementation and more predictable behavior. Eight statement types instead of forty. That constraint saves work in every phase of the compiler.

2. **Data flow classification**: Every action has a role — request, own, response, or export. That role determines valid operations and enables static analysis without reading implementation code.

3. **Immutability by default**: Variables cannot be rebound, eliminating whole categories of bugs and enabling safe concurrency. The semantic analyzer enforces it; the runtime double-checks.

4. **Code as error message**: The source code itself becomes the debugging tool. The statement you wrote, with variable values substituted in, is the error message. Simple, always accurate, occasionally revealing things you'd rather not reveal.

These choices have concrete implementation consequences throughout the codebase. The following chapters examine how each compiler phase and runtime component realizes these principles.

---

*Next: Chapter 2 — Lexical Analysis*
