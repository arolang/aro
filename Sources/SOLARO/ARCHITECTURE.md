# SOLARO architecture

Quick reference for engineers entering the SOLARO codebase. The
authoritative design lives in [issue #228 — note 8488 ADRs](https://git.ausdertechnik.de/arolang/aro/-/issues/228#note_8488)
and the wireframes in [note 8467](https://git.ausdertechnik.de/arolang/aro/-/issues/228#note_8467).

## Platform pivot (2026-06)

SOLARO was originally built on SwiftCrossUI for one-binary cross-platform
shipping. The v0.6 widget set turned out to be too minimal to render
the wireframes' visual style (no theming primitives, no segmented
controls, no asset catalog, no real splitters). The whole UI layer was
rewritten on native **SwiftUI + AppKit on macOS**, dropping Linux and
Windows for now. The design stays portable in spirit — cross-platform
SOLARO can return when SwiftCrossUI matures or when we accept a
parallel front-end.

## Targets

```
Sources/
├── SOLARO/                       ← desktop app (macOS, this directory)
│   ├── SOLAROApp.swift           ← @main, WindowGroup, .onOpenURL launcher path
│   ├── Theme.swift               ← SolaroColor / SolaroFont / SolaroSpace / SolaroRadius
│   ├── WorkspaceState.swift      ← welcome ↔ open routing
│   ├── Welcome.swift             ← welcome (NSOpenPanel + recents tiles)
│   ├── Workspace.swift           ← shell (NavigationSplitView + toolbar + sheets)
│   ├── Sidebar.swift             ← Files / Features / Plugins tabs
│   ├── FileTree.swift            ← directory-grouped tree builder
│   ├── CenterPane.swift          ← Text / Canvas / Split / Map dispatcher
│   ├── CodeEditor.swift          ← NSViewRepresentable around NSTextView
│   ├── SyntaxHighlighter.swift   ← Lexer-driven token coloring
│   ├── CanvasView.swift          ← action-graph rendering + Bézier wires (#232)
│   ├── CanvasGraph.swift         ← node + edge data model
│   ├── ForceDirectedLayout.swift ← fallback placement for unsaved nodes
│   ├── LayoutSidecar.swift       ← per-file .aro.layout.json (ADR-004)
│   ├── ProjectMap.swift          ← feature-set graph data model (note 8519)
│   ├── ProjectMapView.swift      ← domain columns + emit/call wires
│   ├── Inspector.swift           ← right rail (file header + AST tree + deploy rail)
│   ├── StatusBar.swift           ← bottom bar (path / parse / palette / time travel / runtime)
│   ├── OpenAPIEndpoints.swift    ← openapi.yaml discovery (pure logic)
│   ├── OpenAPIPaletteView.swift  ← ⌘K palette sheet (note 8467 fig 10)
│   ├── TimeTravelReader.swift    ← reads #229 Phase 4 JSONL
│   ├── TimeTravelView.swift      ← scrubber + detail pane
│   ├── ProjectModel.swift        ← project root + discovered files
│   ├── SourceFileState.swift     ← per-file parsed program state
│   ├── RecentProjects.swift      ← local-only recents (ADR-007)
│   └── LICENSE-NOTICE.md         ← source-available paid (ADR-011)
│
└── SOLAROLauncher/               ← tiny launcher CLI (~140 LOC)
    └── main.swift                ← `solaro <path>` → `open -a Solaro.app <path>`
```

## How the pieces connect

```
                ┌───────────────────────────────────────┐
                │     SOLAROApp (@main, SwiftUI App)    │
                │  WorkspaceState routing + onOpenURL   │
                └───────────────┬───────────────────────┘
                                │
                ┌───────────────┴───────────────┐
                │                               │
   ┌──────────────────────────┐    ┌──────────────────────────────┐
   │     WelcomeView          │    │   WorkspaceView              │
   │  - SOLARO wordmark       │    │  NavigationSplitView         │
   │  - Open / Create tiles   │    │  ├── Sidebar (Files/         │
   │  - NSOpenPanel folder    │    │  │    Features/Plugins)      │
   │    picker                │    │  ├── CenterPane              │
   │  - Recent project tiles  │    │  │   ├── CodeEditor (Text)   │
   └──────────────────────────┘    │  │   ├── CanvasView (Canvas) │
                                   │  │   ├── HSplitView (Split)  │
                                   │  │   └── ProjectMapView (Map)│
                                   │  └── Inspector (.inspector)  │
                                   │  toolbar: mode picker + run  │
                                   │  + status pip + close        │
                                   │  StatusBar (bottom row)      │
                                   │  sheets: OpenAPIPaletteView, │
                                   │          TimeTravelView      │
                                   └──────────────┬───────────────┘
                                                  │
                                   ┌──────────────┴───────────────┐
                                   │  WorkspaceController         │
                                   │  (@Observable)               │
                                   │  - project / model           │
                                   │  - currentFile / paneMode    │
                                   │  - programs / parseErrors    │
                                   │  - sidebarTab / inspector    │
                                   │  - search text               │
                                   └──────────────┬───────────────┘
                                                  │
                                   ┌──────────────┴───────────────┐
                                   │ AROParser + ARORuntime       │
                                   │  embedded in-process         │
                                   │     per ADR-002              │
                                   └──────────────────────────────┘
```

## ADR map (post-pivot)

| ADR | What it shaped here |
|---|---|
| 001 | SOLARO is a separate `SOLARO` SwiftPM target, macOS-only after the 2026-06 pivot |
| 002 | `Package.swift` lists `AROParser` and `ARORuntime` as direct dependencies — no subprocess to `aro` |
| 003 | `WelcomeView` + `InspectorPane` + `StatusBar` show `AROVersion.shortVersion`; release tags pin the runtime |
| 004 | `LayoutSidecar` writes `.aro.layout.json` next to each source file (gitignored by default via root .gitignore) |
| 005 | `PaneMode` enum cases match the four wireframe modes; sidecar persists the choice per file |
| 007 | `RecentProjects` stores locally only; no telemetry SDK in the dep graph |
| 008 | `WelcomeView` renders only an Open folder / Create project pair plus the recent-projects list |
| 009 | No persona doors anywhere in the UI — see `WelcomeView` |
| 010 | No metric collection |
| 011 | `LICENSE-NOTICE.md` ships with the source under `Sources/SOLARO` |
| 012 | CI (`build.yml`) builds macOS .app, signs + notarizes on tag, attaches DMG to the release |
| 013 | `solaro` launcher CLI helps terminal users — no community chat plumbing |
| 014 | Plugin loading happens at the `aro` CLI; SOLARO embeds the same loader code via `ARORuntime` |
| 016 | `InspectorPane`, `CanvasView`, `ProjectMapView`, `OpenAPIPaletteView`, `TimeTravelView` all show honest empty states |

## Build / run / test

```bash
# Local build
swift build --product SolaroApp
swift build --product solaro

# Run tests
swift test --filter SOLAROTests

# Assemble a .app bundle for development
./tools/build-solaro-app-local.sh release

# Launch via the launcher
export SOLARO_APP="$(pwd)/.build/SOLARO.app"
./.build/release/solaro ./Examples/HelloWorld
```

## Phase status

| Phase | Status | Notes |
|---|---|---|
| 1 — Platform pivot | ✅ shipped | SwiftCrossUI removed; SwiftUI/AppKit foundation in place |
| 2 — Theme | ✅ shipped | SolaroColor / SolaroFont / spacing / radius tokens |
| 3 — Welcome | ✅ shipped | NSOpenPanel folder picker, create-project scaffold, recents |
| 4 — Workspace shell | ✅ shipped | NavigationSplitView + .inspector + native toolbar |
| 5 — Sidebar | ✅ shipped | Files / Features / Plugins, native sidebar list selection |
| 6 — Inspector | ✅ shipped | File header, AST tree with role stripes, deploy rail |
| 7 — Text editor | ✅ shipped | NSTextView + line gutter + syntax highlighting |
| 8 — Canvas | ✅ shipped | Dot grid, pan + zoom, role-striped action cards |
| 9 — Bézier wires | ✅ shipped | Preposition-colored cubic curves, connection legend (#232) |
| 10 — Project Map + Split | ✅ shipped | Domain columns + emit/call wires, double-click drill-down |
| 11 — Palette + time travel + status bar | ✅ shipped | ⌘K palette, JSONL scrubber, bottom status bar |
| 12 — CI + tests + docs | ✅ shipped | Linux CI jobs dropped; docs refreshed |

## Recent additions (2026-06)

Live-state pipeline. Every per-statement update — canvas pulses,
inline values, paused-line tint, error border, repository
payloads, test PASS/FAIL chips — flows through one fanout:
`Debug.controller` (TaskLocal in ARORuntime) → `JSONLEventWriter`
→ `.solaro/events.jsonl` → `LiveEventStream` → `ConsoleProcess`
→ controller state slots. Adding a new live indicator means
adding one field to `ConsoleProcess`, mirroring it onto
`WorkspaceController`, and reading it from the view. Surfaces
that already do this: canvas FS container, canvas node card,
gutter marker, inspector watches, inspector test T badge,
project map.

| File | What it owns |
|---|---|
| `RunParameters.swift` | The pre-run dialog (`RunParametersSheet`), per-project saved values (`RunParameterDefaults`), and the scanner that walks every `AROStatement.object.noun` for `<parameter: NAME>` references — including a disk-fallback (`scanFromDisk`) used when the controller's program cache hasn't filled yet. The dialog disables Execute on blank fields and ships smart per-name placeholders (`https://example.com` for `url`, `localhost` for `host`, etc.). |
| `TestResults.swift` | `TestNodeResult` (passed / failed-with-message) and `TestResultParser.match` — strips ANSI escapes from `aro test` stdout and matches PASS / FAIL / ERROR lines. `Console.appendLine` calls it on every stdout line so the test status mirror updates as the runner walks tests. |
| `NodeEditing.swift` + `SelectedStatementSection.swift` | Per-action editor schemas (`LogEditing`, `CreateEditing`, `ComputeEditing`, `ReturnEditing`, `EmitEditing`, `WithClauseEditing`, `GenericEditing`) wrap a single `EditableField` enum with cases for stringLiteral / identifier / expression / picker / record / combo. `NodeEditorView` renders the field list, `SelectedStatementSection` renders the same form read-write inside the Inspector. Apply hits `controller.nodeEditApply` which CenterPane wires to the existing save-and-reparse pipeline. |
| `QualifierCatalog.swift` | Snapshot of `ARORuntime.QualifierRegistry.allRegistrations()` keyed by `namespace.qualifier`. Used to populate the modifier dropdown in the editor; built-ins drop the `_builtin` namespace, plugin qualifiers keep theirs so `collections.reverse` and a future `stats.reverse` stay distinct. |
| `CreateFeatureSetSheet.swift` | Canvas right-click → "Create new Feature Set…" dialog. `NewFeatureSetDraft` collects name, business activity, optional `when`, and (for `Action` activities) the `takes <name: Type>` parameter. `FeatureSetTemplate.render` emits a minimal valid block; CenterPane appends it through the same `saveAndReparse` pipeline that statement edits use. |
| `AroBinaryVersion.swift` | Probes the resolved `aro --version` once per workspace open and shows a yellow banner when the version disagrees with `AROVersion.shortVersion`. Dismissal is scoped to the `(path, binary version, solaro version)` triple so a new drift still surfaces. |
| `RunParameterDefaults` in `RunParameters.swift` | Per-project parameter persistence at `~/Library/Application Support/SOLARO/parameters/<hash>.json` keyed by a deterministic hash of the project root path. |
| `WorkspaceController.testResults: [String: TestNodeResult]` | The single source of truth for test PASS/FAIL state across every surface. Populated from `ConsoleProcess.testResults` via the `executionTick` onChange in `WorkspaceView`. |
| `WorkspaceController.selectedNode` + `selectedNodeSource` | Single-clicking a canvas node mirrors it here so the Inspector's "Selected Statement" form renders without re-resolving the source span. |
| `WorkspaceController.isLoading` + `loadTask` | The project parse runs on a detached task off the main actor; `isLoading` gates the Run / Debug / Test buttons so a launch can't fire with a half-populated cache. |
| Runtime `errorCheckpoint` plumbing | `FeatureSetExecutor.executeStatement` catches every throw, calls `Debug.controller?.errorCheckpoint(message:line:file:)` with the failing statement's span, and re-throws. SOLARO's embedded frontend translates the `.error` reason into a `TimeTravelRecord(kind: .error)` and the canvas paints the red border via `errorLines[line]`. |

## Where to learn more

- [Issue #228](https://git.ausdertechnik.de/arolang/aro/-/issues/228) — design + wireframes
- [Issue #229](https://git.ausdertechnik.de/arolang/aro/-/issues/229) — debugger; SOLARO consumes its JSONL log
- [Issue #232](https://git.ausdertechnik.de/arolang/aro/-/issues/232) — Bézier wires (delivered)
- [Issue #233](https://git.ausdertechnik.de/arolang/aro/-/issues/233) — remaining follow-ups
- [Issue #234](https://git.ausdertechnik.de/arolang/aro/-/issues/234) — Phase 4 distribution
- [Issue #266](https://git.ausdertechnik.de/arolang/aro/-/issues/266) — canvas multi-select (partial)
- [Issue #282](https://git.ausdertechnik.de/arolang/aro/-/issues/282) — embedded ARO runtime (phase 1)
- [Issues #284 / #285 / #289](https://git.ausdertechnik.de/arolang/aro/-/issues/284) — file-size split refactors
- [Issue #292](https://git.ausdertechnik.de/arolang/aro/-/issues/292) — this doc's last refresh
