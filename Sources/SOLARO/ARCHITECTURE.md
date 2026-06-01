# SOLARO architecture

Quick reference for engineers entering the SOLARO codebase. The
authoritative design lives in [issue #228 — note 8488 ADRs](https://git.ausdertechnik.de/arolang/aro/-/issues/228#note_8488)
and the 11 wireframes in [note 8467](https://git.ausdertechnik.de/arolang/aro/-/issues/228#note_8467).

## Targets

```
Sources/
├── SOLARO/                 ← desktop app (this directory)
│   ├── SOLAROApp.swift     ← @main entry
│   ├── Welcome.swift       ← welcome screen (ADR-008)
│   ├── Workspace.swift     ← four-zone shell
│   ├── FileTreePane.swift  ← left rail
│   ├── CenterPane.swift    ← Text / Canvas / Split / Map
│   ├── InspectorPane.swift ← right rail (AST + deploy)
│   ├── CanvasGraph.swift   ← Phase 2 — node + edge model
│   ├── ForceDirectedLayout.swift
│   ├── CanvasView.swift
│   ├── ProjectMap.swift    ← Phase 3 — feature-set graph (note 8519)
│   ├── ProjectMapView.swift
│   ├── OpenAPIPalette.swift
│   ├── TimeTravelReader.swift  ← reads #229 Phase 4 JSONL
│   ├── TimeTravelView.swift
│   ├── ProjectModel.swift
│   ├── SourceFileState.swift
│   ├── LayoutSidecar.swift
│   ├── RecentProjects.swift
│   ├── WorkspaceState.swift
│   └── LICENSE-NOTICE.md    ← ADR-011 source-available paid
│
└── SOLAROLauncher/         ← tiny launcher CLI (~140 LOC)
    └── main.swift
```

## How the pieces connect

```
                ┌───────────────────────────────┐
                │     SOLAROApp (@main)         │
                │  ─ WorkspaceState routing     │
                └───────────────┬───────────────┘
                                │
                ┌───────────────┴───────────────┐
                │                               │
   ┌─────────────────────────┐    ┌────────────────────────┐
   │     WelcomeView          │    │   WorkspaceView        │
   │  - Open folder…          │    │  - file tree           │
   │  - Create project…       │    │  - center pane         │
   │  - recent projects       │    │     • Text             │
   │  - manual path entry     │    │     • Canvas (Phase 2) │
   └─────────────────────────┘    │     • Split             │
                                  │     • Map (Phase 3)    │
                                  │  - inspector pane      │
                                  │     • AST inspector    │
                                  │     • deploy rail      │
                                  └────────┬───────────────┘
                                           │
                                  ┌────────┴────────────────┐
                                  │ shared model            │
                                  │  - ProjectModel         │
                                  │  - SourceFileState      │
                                  │  - LayoutSidecar         │
                                  │  - RecentProjects       │
                                  └─────────────────────────┘
                                           │
                                  ┌────────┴────────────────┐
                                  │ AROParser + ARORuntime  │
                                  │  embedded in-process     │
                                  │     per ADR-002         │
                                  └─────────────────────────┘
```

## ADR map

| ADR | What it shaped here |
|---|---|
| 001 | SOLARO is a separate executable target (`Sources/SOLARO`), not an `aro` subcommand |
| 002 | `Package.swift` lists `AROParser` and `ARORuntime` as direct dependencies — no subprocess to `aro` |
| 003 | `WelcomeView` shows `AROVersion.shortVersion` in its banner; release tags pin the runtime |
| 004 | `LayoutSidecar` writes `.aro.layout.json` next to each source file; users gitignore it by default |
| 005 | `PaneMode` enum cases match the four wireframe modes; the sidecar persists the choice per file |
| 006 | (Phase 3 follow-up) — first-use "configure AI" picker not yet wired |
| 007 | `RecentProjects` stores locally only; no telemetry SDK in the dep graph |
| 008 | `WelcomeView` renders only an Open folder / Create project pair plus the recent-projects list |
| 009 | No persona doors anywhere in the UI — see `WelcomeView` |
| 010 | No metric collection; the README will document the no-feedback-loop posture |
| 011 | `LICENSE-NOTICE.md` ships with the source under `Sources/SOLARO` |
| 012 | CI (`build.yml`, `.gitlab-ci.yml`) builds macOS .app + Linux tarball; macOS signs on tag |
| 013 | `solaro` launcher CLI helps terminal users; no Discord/Matrix in dep graph |
| 014 | Plugin loading happens at the `aro` CLI; SOLARO embeds the same loader code via `ARORuntime` |
| 015 | (Phase 4 follow-up) — docs site lunr.js search not yet wired |
| 016 | `InspectorPane` and `CanvasView` show honest empty states; no tutorial wizard |

## Build / run / test

```bash
# Local build
swift build --product SOLARO
swift build --product solaro

# Run tests (non-UI logic only — there's no headless SwiftCrossUI yet)
swift test --filter SOLAROTests

# Launch the app from the terminal (after install or via a debug build)
swift run SOLARO

# Or via the launcher (when SOLARO.app is installed)
solaro .
```

## Phase status

| Phase | Status | Notes |
|---|---|---|
| 0 — Foundations | ✅ shipped | SwiftPM scaffold, launcher CLI, welcome screen, CI |
| 1 — Source editing | ✅ shipped | Four-zone shell, AST inspector, layout sidecar |
| 2 — Canvas mode | ✅ shipped (text-rows) | Bézier wires waiting on #232 |
| 3 — Killer features | ⚠️ partial | Time travel + Project Map + OpenAPI palette landed; #233 tracks the rest |
| 4 — Distribution | ⚠️ partial | macOS .app + Linux tarball + release attach landed in Phase 0 CI |

## Where to learn more

- [Issue #228](https://git.ausdertechnik.de/arolang/aro/-/issues/228) — design + wireframes
- [Issue #229](https://git.ausdertechnik.de/arolang/aro/-/issues/229) — debugger; SOLARO consumes its JSONL log
- [Issue #232](https://git.ausdertechnik.de/arolang/aro/-/issues/232) — Bézier wires (the visual gap Phase 2 left)
- [Issue #233](https://git.ausdertechnik.de/arolang/aro/-/issues/233) — Phase 3 follow-ups
