# ARO: Business Logic as Language

Chapter numbers in this file match the file names in `Book/TheLanguageGuide/`.

---

## Part I: Philosophy & Foundations

1. **Why ARO?** — The problem with imperative business code
2. **The ARO Mental Model** — Actions, Results, Objects as first-class citizens
3. **Getting Started** — Installation, first application, `aro run`

---

## Part II: Core Language

4. **Anatomy of a Statement** — `Action the <Result> preposition the <Object>`
5. **String Literals** — Regular strings, raw strings, escape sequences, interpolation
6. **Feature Sets** — Naming, business activities, scoping
7. **Data Flow** — Semantic roles (REQUEST, OWN, RESPONSE, EXPORT)
8. **Export Actions** — Choosing between Store, Emit, and Publish
9. **Computations** — Transform and compute data with built-in operations
10. **Understanding Qualifiers** — Operation selectors vs field navigation
11. **Immutability** — The binding model, new-name pattern, pipeline naming, loop isolation
12. **The Happy Path** — Why there's no error handling (and why that's okay)

---

## Part III: Event-Driven Architecture

13. **The Event Bus** — How feature sets get triggered
14. **Application Lifecycle** — Start, End, Keepalive
15. **Custom Events** — Emit, handlers, event-driven design
16. **Handler Guards** — Declaration-level filtering with `when` and `<field:value>` guards

---

## Part IV: Contract-First APIs

17. **OpenAPI Integration** — Your contract is your router
18. **HTTP Feature Sets** — operationId as feature set name
19. **Request/Response Patterns** — Extract, Return, path parameters

---

## Part V: Services & Extensions

20. **Built-in Services** — HTTP, files, sockets
21. **Format-Aware File I/O** — Automatic serialization by file extension
22. **System Objects** — Sources, sinks, and the unified I/O pattern
23. **Command-Line Parameters** — The `parameter` system object, argument syntax, defaults
24. **Custom Actions** — Adding new verbs to ARO
25. **Custom Services** — External integrations via Call action
26. **Plugins** — Packaging and distributing extensions

---

## Part VI: Production

27. **Native Compilation** — `aro build` and the C runtime
28. **Code Signing** — Distributing macOS binaries with Gatekeeper, Developer ID, and notarization
29. **Multi-file Applications** — Project structure
30. **Patterns & Practices** — Real-world architectures
31. **State Machines** — Lifecycle management with the Accept action
32. **Modules and Imports** — Modular architecture and cross-module visibility

---

## Part VII: Advanced Topics

33. **Control Flow** — Guards, match expressions, regex patterns, conditional execution
34. **Data Pipelines** — Map, Filter, Reduce for collection processing
35. **Set Operations** — intersect, difference, union across lists, strings, and objects
36. **Repositories** — Persistent in-memory storage and observers
37. **System Commands** — Shell execution with the Exec action
38. **HTTP Client** — Making requests to external services
39. **Concurrency** — Feature sets are async, statements are sync
40. **Context-Aware Responses** — Human, machine, and developer output formatting
41. **Type System** — Primitives, collections, and OpenAPI schemas
42. **Date and Time** — Temporal operations, comparisons, and formatting
43. **Runtime Metrics** — Execution counts, timing, and Prometheus integration
44. **Templates** — Dynamic content generation with `{{ }}` blocks
45. **WebSockets** — Real-time bidirectional communication
46. **Streaming Execution** — Process large datasets with constant memory
47. **Terminal UI** — Interactive terminal applications, section compositor, keyboard handlers

---

## Appendices

- **A**: Action Reference (all built-in actions)
- **B**: Preposition Semantics
- **C**: Statements Reference
