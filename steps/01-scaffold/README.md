# Step 01 — Scaffold

> Goal: understand what `create-plugin` generated, get Grafana running, and establish the dev loop.

## What was generated

```
tutorial-miniops-app/
  src/
    module.tsx          ← plugin entry point, registers the SceneApp
    plugin.json         ← plugin metadata (id, type, nav entries)
    constants.ts        ← shared constants (ROUTES, DATASOURCE_REF)
    pages/
      Home/             ← a scene with query runner + variable + custom object
      WithDrilldown/    ← demonstrates page-to-page navigation
      WithTabs/         ← demonstrates tab layout
      HelloWorld/       ← minimal scene, good read for step 02
    components/         ← shared React components
    utils/              ← routing helpers
  dist/                 ← webpack output, mounted into Grafana by docker-compose
  provisioning/         ← tells Grafana to auto-enable this plugin on startup
  .config/              ← managed by @grafana/plugin-tools, do not edit
  docker-compose.yaml   ← extends .config/docker-compose-base.yaml
```

The key relationship: **`dist/` is mounted as a volume into the Grafana container**. Every time webpack emits new output (dev watch or build), Grafana sees the change immediately — no container restart needed for JS changes. `plugin.json` changes require a Grafana restart.

## Starting the dev loop

Open two terminals:

**Terminal 1** — webpack watch mode:
```bash
cd tutorial-miniops-app
npm run dev
```

**Terminal 2** — Grafana:
```bash
cd tutorial-miniops-app
docker-compose up -d
```

Then open http://localhost:3000. Anonymous access is pre-configured as Admin, so no login needed.

Navigate to **Apps → Mini-Ops** in the left sidebar (or search for it).

## Verify it works

You should see a time series panel with random walk data and a variable selector at the top. If you see it, the scaffold is working correctly.

## What `module.tsx` does

```tsx
// src/module.tsx
import { AppPlugin } from '@grafana/runtime';
import { App } from './components/App/App';

export const plugin = new AppPlugin<{}>().setRootPage(App);
```

`AppPlugin` is the entry point for all Grafana app plugins. `setRootPage` hands control to a React component. For a Scenes app, that component creates and renders a `SceneApp`.

Open `src/components/App/App.tsx` and you'll see it renders a `SceneApp` — the routing-level primitive. We'll dissect that in step 07.

## What `plugin.json` controls

```json
{
  "type": "app",
  "id": "tutorial-miniops-app",
  "includes": [
    { "type": "page", "name": "Home", "path": "/a/tutorial-miniops-app/home", "addToNav": true }
  ]
}
```

`includes` is what populates Grafana's left-nav. Each entry maps a URL path to a page that your `SceneApp` will render. The plugin id in `id` must match the directory name under `/var/lib/grafana/plugins/`.

## What to read before step 02

- `src/pages/HelloWorld/` — the simplest scene in the scaffold, about 30 lines
- `src/pages/Home/homeScene.ts` — the most complete example; don't worry about understanding all of it yet

**Next:** [Step 02 — The Object Model](../02-object-model/README.md)
