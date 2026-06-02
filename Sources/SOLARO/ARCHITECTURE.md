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
    └── main.swift                ← `solaro <path>` → `open -a SOLARO.app <path>`
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

## Where to learn more

- [Issue #228](https://git.ausdertechnik.de/arolang/aro/-/issues/228) — design + wireframes
- [Issue #229](https://git.ausdertechnik.de/arolang/aro/-/issues/229) — debugger; SOLARO consumes its JSONL log
- [Issue #232](https://git.ausdertechnik.de/arolang/aro/-/issues/232) — Bézier wires (delivered)
- [Issue #233](https://git.ausdertechnik.de/arolang/aro/-/issues/233) — remaining follow-ups (PR diff,
  live wires, sub-graph publish, LLM co-pilot, Report a Bug, Map polish)
- [Issue #234](https://git.ausdertechnik.de/arolang/aro/-/issues/234) — Phase 4 distribution
  items (iPad, AppImage, MSI, landing page, deploy adapters)
