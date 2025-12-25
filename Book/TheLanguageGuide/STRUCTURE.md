# ARO: Business Logic as Language

## Part I: Philosophy & Foundations
1. **Why ARO?** — The problem with imperative business code
2. **The ARO Mental Model** — Actions, Results, Objects as first-class citizens
3. **Getting Started** — Installation, first application, `aro run`

## Part II: Core Language
4. **Anatomy of a Statement** — `<Action> the <Result> preposition the <Object>`
5. **Feature Sets** — Naming, business activities, scoping
6. **Data Flow** — Semantic roles (REQUEST, OWN, RESPONSE, EXPORT)
7. **The Happy Path** — Why there's no error handling (and why that's okay)

## Part III: Event-Driven Architecture
8. **The Event Bus** — How feature sets get triggered
9. **Application Lifecycle** — Start, End, Keepalive
10. **Custom Events** — Emit, handlers, event-driven design

## Part IV: Contract-First APIs
11. **OpenAPI Integration** — Your contract is your router
12. **HTTP Feature Sets** — operationId as feature set name
13. **Request/Response Patterns** — Extract, Return, path parameters

## Part V: Services & Extensions
14. **Built-in Services** — HTTP, files, sockets
15. **Custom Actions** — Writing Swift extensions
16. **Plugins** — Package.swift integration

## Part VI: Production
17. **Native Compilation** — `aro build` and the C runtime
18. **Multi-file Applications** — Project structure
19. **Patterns & Practices** — Real-world architectures
20. **State Machines** — Lifecycle management with the Accept action
21. **Modules and Imports** — Modular architecture and cross-module visibility

## Appendices
- A: Action Reference (all 24 built-in actions)
- B: Preposition Semantics
- C: Grammar Specification
