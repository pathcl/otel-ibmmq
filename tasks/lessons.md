# Lessons

## SceneDataTransformer custom operator: read the source before implementing

**What went wrong**: Shipped the operator in two wrong shapes before it worked:
1. `{ operator: (source) => source.pipe(map(...)) }` → `e.pipe is not a function`
2. `{ operator: (frames) => buildNodeGraphFrames(frames) }` → `e.filter is not a function`

**Root cause**: `SceneDataTransformer` strips the `{ operator: fn }` wrapper and passes `fn` raw to `@grafana/data`'s `transformDataFrame`. That function treats any plain `function` as a custom transformation and calls it as `fn(context)`, expecting the return value to be an `OperatorFunction<DataFrame[], DataFrame[]>`. The argument is the `DataTransformContext` object — not an Observable, not an array.

**Correct shape**:
```ts
{ operator: (_ctx: DataTransformContext) => (source: Observable<DataFrame[]>) => source.pipe(map(frames => transform(frames))) }
```

**Rule**: Before implementing any `SceneDataTransformer` custom operator, read `node_modules/@grafana/data/dist/cjs/transformations/transformDataFrame.cjs` to confirm the exact call signature. TypeScript types do not protect against this — the wrong shape compiles cleanly.

---

## npm run build is not a test

**What went wrong**: After each operator fix, I ran `npm run build`, saw no errors, and reported success. The plugin crashed immediately on load with a runtime TypeError.

**Rule**: After any Grafana plugin change that affects runtime behavior, verify in the browser before calling it done. Check the developer console for errors after the page loads. `npm run build` only validates TypeScript types, not runtime behavior.

---

## TraceQL: no bracket notation in Tempo 2.6.x

**What went wrong**: Used `{span["tenant.id"] != ""}` — Tempo 2.6.1 returns `parse error at line 1, col 2: syntax error: unexpected IDENTIFIER`.

**Rule**: For span attributes with dots in the key (e.g. `tenant.id`), use dot notation directly: `{.tenant.id != ""}`. Verify TraceQL syntax with `curl http://localhost:3200/api/search?q=<encoded_query>` before wiring it into a panel.

---

## rm -rf dist breaks Docker bind mounts — use docker compose up -d after cleaning

**What went wrong**: `rm -rf dist` deleted the directory inode that Docker's bind mount was tracking. webpack created a new `dist` with a new inode, so Grafana still served the old (now empty) inode → `module.js 404` → blank plugin page.

**Rule**: After any `rm -rf dist` (or `prebuild` script that does the same), run `docker compose up -d --no-deps grafana` (not `restart`) to recreate the container and re-establish the bind mount against the new inode. `restart` reuses the old mount; `up -d` remounts.

---

## Webpack does not clean dist between builds — add a prebuild script

**What went wrong**: Old chunk `695.js` (with `span["tenant.id"]`) survived multiple rebuilds. The browser cached `module.js` referencing that chunk and kept loading the old query, so fixes appeared to have no effect.

**Rule**: Always add `"prebuild": "rm -rf dist"` to `package.json` scripts so every `npm run build` starts clean. npm runs `prebuild` automatically before `build`. Without this, webpack only emits new/changed chunks and leaves stale ones in place.

---

## stream_over_http_enabled: true breaks Grafana trace search in Tempo 2.10.x

**What went wrong**: `stream_over_http_enabled: true` in `tempo.yaml` instructs Grafana's Tempo backend plugin to use `/api/v3/search` for TraceQL queries. That endpoint returns 404 in Tempo 2.10.7, so Grafana silently returns empty results — "No data found in response" — even though `/api/search` works fine.

**Rule**: Do not set `stream_over_http_enabled: true` unless you have confirmed the Grafana Tempo datasource version supports the streaming endpoint for the installed Tempo version. Verify with `curl http://localhost:3200/api/v3/search?q={}` — if it returns 404, remove the setting.

---

## Verify API contracts with curl before wiring into panels

**What went wrong**: Wrote the Prometheus and Tempo queries based on assumptions. Several caused 400 errors that only surfaced after the plugin was rebuilt and loaded.

**Rule**: Before using any external API query in a panel, test it directly:
- Prometheus: `curl 'http://localhost:9090/api/v1/query?query=<expr>'`
- Tempo TraceQL: `curl 'http://localhost:3200/api/search?q=<encoded>&limit=5'`

This costs 30 seconds and saves multiple build/reload cycles.
