# ARO: Business Logic as Language

## Part I: Philosophy & Foundations
1. **Why ARO?** — The problem with imperative business code
2. **The ARO Mental Model** — Actions, Results, Objects as first-class citizens
3. **Getting Started** — Installation, first application, `aro run`

## Part II: Core Language
4. **Anatomy of a Statement** — `<Action> the <Result> preposition the <Object>`
5. **Feature Sets** — Naming, business activities, scoping
6. **Data Flow** — Semantic roles (REQUEST, OWN, RESPONSE, EXPORT)
7. **Export Actions** — Choosing between Store, Emit, and Publish
8. **Computations** — Transform and compute data with built-in operations
9. **Understanding Qualifiers** — Operation selectors vs field navigation
10. **The Happy Path** — Why there's no error handling (and why that's okay)

## Part III: Event-Driven Architecture
11. **The Event Bus** — How feature sets get triggered
12. **Application Lifecycle** — Start, End, Keepalive
13. **Custom Events** — Emit, handlers, event-driven design

## Part IV: Contract-First APIs
14. **OpenAPI Integration** — Your contract is your router
15. **HTTP Feature Sets** — operationId as feature set name
16. **Request/Response Patterns** — Extract, Return, path parameters

## Part V: Services & Extensions
17. **Built-in Services** — HTTP, files, sockets
18. **Format-Aware File I/O** — Automatic serialization by file extension
18B. **System Objects** — Sources, sinks, and the unified I/O pattern
19. **Custom Actions** — Adding new verbs to ARO
20. **Custom Services** — External integrations via Call action
21. **Plugins** — Packaging and distributing extensions

## Part VI: Production
22. **Native Compilation** — `aro build` and the C runtime
23. **Multi-file Applications** — Project structure
24. **Patterns & Practices** — Real-world architectures
25. **State Machines** — Lifecycle management with the Accept action
26. **Modules and Imports** — Modular architecture and cross-module visibility

## Part VII: Advanced Topics
27. **Control Flow** — Guards, match expressions, regex patterns, conditional execution
28. **Data Pipelines** — Map, Filter, Reduce for collection processing
29. **Repositories** — Persistent in-memory storage and observers
30. **System Commands** — Shell execution with the Exec action
31. **HTTP Client** — Making requests to external services
32. **Concurrency** — Feature sets are async, statements are sync
33. **Context-Aware Responses** — Human, machine, and developer output formatting
34. **Type System** — Primitives, collections, and OpenAPI schemas
35. **Date and Time** — Temporal operations, comparisons, and formatting
36. **Runtime Metrics** — Execution counts, timing, and Prometheus integration
37. **Template Engine** — Dynamic content generation with `{{ }}` blocks
38. **WebSockets** — Real-time bidirectional communication
39. **Streaming Execution** — Process large datasets with constant memory

## Appendices
- A: Action Reference (all 50 built-in actions)
- B: Preposition Semantics
- C: Statements Reference
