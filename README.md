# Grafana Scenes Tutorial

A hands-on tutorial for Python/Go developers learning the `@grafana/scenes` ecosystem through a **Mini Ops Dashboard** app plugin.

## What you'll build

A Grafana app plugin that displays operational metrics using Grafana Scenes — the same library powering Grafana Incident, the k6 app, and most first-party Grafana apps.

## Tutorial steps

| Step | Topic | Primitives covered |
|------|-------|--------------------|
| [01 — Scaffold](steps/01-scaffold/README.md) | Project setup, dev loop | `create-plugin`, docker-compose, webpack dev watch |
| 02 — Object model | The base class everything inherits | `SceneObjectBase`, `SceneObjectState`, `setState()`, `subscribeToState()` |
| 03 — First scene | Your first working panel | `EmbeddedScene`, `SceneFlexLayout`, `VizPanel`, `PanelBuilders` |
| 04 — Data & time | Wiring queries and the time range | `SceneQueryRunner`, `SceneTimeRange`, `SceneTimePicker`, `SceneRefreshPicker` |
| 05 — Variables | Making scenes dynamic | `SceneVariableSet`, `DataSourceVariable`, `QueryVariable`, `CustomVariable` |
| 06 — Layout systems | Flex vs Grid vs CSS Grid | `SceneGridLayout`, `SceneCSSGridLayout`, when to use each |
| 07 — Multi-page app | Routing and URL sync | `SceneApp`, `SceneAppPage`, `UrlSyncManager` |
| 08 — Behaviors | Behavioral mixins and repeaters | `behaviors.*`, `SceneByVariableRepeater` |

## Prerequisites

- Node.js 22+ (via asdf: `asdf set nodejs 22.17.0`)
- Docker + docker-compose
- Familiarity with TypeScript basics (the tutorial explains concepts, not syntax)

## Plugin location

All code lives in `tutorial-miniops-app/`. Steps reference specific files within it.

## Running Grafana

```bash
# From tutorial-miniops-app/
npm run dev              # watch mode — rebuilds on file save
docker-compose up -d     # Grafana at http://localhost:3000
```
