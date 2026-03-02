# ARO: Business Logic as Language

Chapter numbers in this file match the file names in `Book/TheLanguageGuide/`.
`Chapter04B-RawStrings.md` → **4B**, `Chapter09B-Immutability.md` → **9B**, etc.

---

## Part I: Philosophy & Foundations

1. **Why ARO?** — The problem with imperative business code
2. **The ARO Mental Model** — Actions, Results, Objects as first-class citizens
3. **Getting Started** — Installation, first application, `aro run`

---

## Part II: Core Language

4. **Anatomy of a Statement** — `Action the <Result> preposition the <Object>`
4B. **String Literals** — Regular strings, raw strings, escape sequences, interpolation
5. **Feature Sets** — Naming, business activities, scoping
6. **Data Flow** — Semantic roles (REQUEST, OWN, RESPONSE, EXPORT)
7. **Export Actions** — Choosing between Store, Emit, and Publish
8. **Computations** — Transform and compute data with built-in operations
9. **Understanding Qualifiers** — Operation selectors vs field navigation
9B. **Immutability** — The binding model, new-name pattern, pipeline naming, loop isolation
10. **The Happy Path** — Why there's no error handling (and why that's okay)

---

## Part III: Event-Driven Architecture

11. **The Event Bus** — How feature sets get triggered
12. **Application Lifecycle** — Start, End, Keepalive
13. **Custom Events** — Emit, handlers, event-driven design
13B. **Handler Guards** — Declaration-level filtering with `when` and `<field:value>` guards

---

## Part IV: Contract-First APIs

14. **OpenAPI Integration** — Your contract is your router
15. **HTTP Feature Sets** — operationId as feature set name
16. **Request/Response Patterns** — Extract, Return, path parameters

---

## Part V: Services & Extensions

17. **Built-in Services** — HTTP, files, sockets
18. **Format-Aware File I/O** — Automatic serialization by file extension
19. **System Objects** — Sources, sinks, and the unified I/O pattern
19B. **Command-Line Parameters** — The `parameter` system object, argument syntax, defaults
20. **Custom Actions** — Adding new verbs to ARO
21. **Custom Services** — External integrations via Call action
22. **Plugins** — Packaging and distributing extensions

---

## Part VI: Production

23. **Native Compilation** — `aro build` and the C runtime
24. **Multi-file Applications** — Project structure
25. **Patterns & Practices** — Real-world architectures
26. **State Machines** — Lifecycle management with the Accept action
27. **Modules and Imports** — Modular architecture and cross-module visibility

---

## Part VII: Advanced Topics

28. **Control Flow** — Guards, match expressions, regex patterns, conditional execution
29. **Data Pipelines** — Map, Filter, Reduce for collection processing
29B. **Set Operations** — intersect, difference, union across lists, strings, and objects
30. **Repositories** — Persistent in-memory storage and observers
31. **System Commands** — Shell execution with the Exec action
32. **HTTP Client** — Making requests to external services
33. **Concurrency** — Feature sets are async, statements are sync
34. **Context-Aware Responses** — Human, machine, and developer output formatting
35. **Type System** — Primitives, collections, and OpenAPI schemas
36. **Date and Time** — Temporal operations, comparisons, and formatting
37. **Runtime Metrics** — Execution counts, timing, and Prometheus integration
38. **Templates** — Dynamic content generation with `{{ }}` blocks
39. **WebSockets** — Real-time bidirectional communication
40. **Streaming Execution** — Process large datasets with constant memory
41. **Terminal UI** — Interactive terminal applications, section compositor, keyboard handlers

---

## Appendices

- **A**: Action Reference (all built-in actions)
- **B**: Preposition Semantics
- **C**: Statements Reference
