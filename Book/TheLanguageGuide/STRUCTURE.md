# ARO: Business Logic as Language

## Part I: Philosophy & Foundations
1. **Why ARO?** — The problem with imperative business code
2. **The ARO Mental Model** — Actions, Results, Objects as first-class citizens
3. **Getting Started** — Installation, first application, `aro run`

## Part II: Core Language
4. **Anatomy of a Statement** — `<Action> the <Result> preposition the <Object>`
5. **Feature Sets** — Naming, business activities, scoping
6. **Data Flow** — Semantic roles (REQUEST, OWN, RESPONSE, EXPORT)
7. **Computations** — Transform and compute data with built-in operations
8. **The Happy Path** — Why there's no error handling (and why that's okay)

## Part III: Event-Driven Architecture
9. **The Event Bus** — How feature sets get triggered
10. **Application Lifecycle** — Start, End, Keepalive
11. **Custom Events** — Emit, handlers, event-driven design

## Part IV: Contract-First APIs
12. **OpenAPI Integration** — Your contract is your router
13. **HTTP Feature Sets** — operationId as feature set name
14. **Request/Response Patterns** — Extract, Return, path parameters

## Part V: Services & Extensions
15. **Built-in Services** — HTTP, files, sockets
16. **Custom Actions** — Writing Swift extensions
17. **Plugins** — Package.swift integration

## Part VI: Production
18. **Native Compilation** — `aro build` and the C runtime
19. **Multi-file Applications** — Project structure
20. **Patterns & Practices** — Real-world architectures
21. **State Machines** — Lifecycle management with the Accept action
22. **Modules and Imports** — Modular architecture and cross-module visibility

## Part VII: Advanced Topics
23. **Control Flow** — Guards, match expressions, conditional execution
24. **Data Pipelines** — Map, Filter, Reduce for collection processing
25. **Repositories** — Persistent in-memory storage and observers
26. **System Commands** — Shell execution with the Exec action
27. **HTTP Client** — Making requests to external services
28. **Concurrency** — Feature sets are async, statements are sync
29. **Context-Aware Responses** — Human, machine, and developer output formatting
30. **Type System** — Primitives, collections, and OpenAPI schemas

## Appendices
- A: Action Reference (all 50 built-in actions)
- B: Preposition Semantics
- C: Grammar Specification
- D: Statements Reference
