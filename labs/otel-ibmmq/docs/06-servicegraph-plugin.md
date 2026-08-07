# 06 — Service Graph Scenes Plugin

## What it does

`otel-mq-app` is a Grafana app plugin built with **Grafana Scenes**. It renders a live service graph showing how the `gateway` and `processor` services interact over IBM MQ, filterable by tenant.

URL: `http://localhost:3001/a/otel-mq-app/home`

## How the data flows

```
spans (OTel SDK)
  │  gateway & processor export to otel-collector → Tempo
  ▼
Tempo metrics_generator
  │  service-graphs processor pairs client + server spans
  │  span attribute tenant.id → Prometheus label tenant_id
  ▼
Prometheus (remote_write receiver on /api/v1/write)
  │  traces_service_graph_request_total{client, server, tenant_id}
  ▼
Grafana Scenes plugin
  │  Tempo serviceMap query   → nodeGraph panel
  │  Prometheus rate() query  → timeseries panel (filtered by $tenant)
```

## Tempo config changes (`tempo/tempo.yaml`)

```yaml
metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /tmp/tempo/generator/wal
    remote_write:
      - url: http://prometheus:9090/api/v1/write
  processor:
    service_graphs:
      dimensions:
        - tenant.id      # becomes tenant_id in Prometheus labels
    span_metrics:
      dimensions:
        - tenant.id

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]
```

`dimensions` tells the service-graphs processor to promote the OTel span attribute
`tenant.id` (dot → underscore by convention) into a Prometheus label. Without this,
metrics would only have `client` and `server` labels.

## Prometheus config change (`docker-compose.yml`)

```yaml
prometheus:
  command:
    - '--config.file=/etc/prometheus/prometheus.yml'
    - '--web.enable-remote-write-receiver'   # Tempo pushes here
```

## Scenes architecture

```
EmbeddedScene
├── $timeRange    SceneTimeRange (last 1h)
├── $variables    SceneVariableSet
│     └── QueryVariable($tenant)
│           datasource: prometheus
│           query: label_values(traces_service_graph_request_total, tenant_id)
│           includeAll: true   → "All" option maps to regex .*
├── body          SceneFlexLayout (column)
│     ├── SceneFlexItem          nodeGraph panel
│     │     └── $data  SceneQueryRunner (Tempo, queryType: serviceMap)
│     └── SceneFlexItem          timeseries panel
│           └── $data  SceneQueryRunner (Prometheus, rate filtered by $tenant)
└── controls      [VariableValueSelectors, SceneTimePicker, SceneRefreshPicker]
```

### Why Tempo's `serviceMap` query type for the node graph?

The Tempo datasource ships a `serviceMap` query type that internally queries
Prometheus for `traces_service_graph_request_*` metrics and returns **two pre-formatted
data frames**: one for nodes (`id`, `title`, `mainStat`, `arc__success`, `arc__error`)
and one for edges (`id`, `source`, `target`, `mainStat`). The `nodeGraph` panel
consumes these directly.

Building the same frames manually from raw Prometheus time-series would require a
multi-step `SceneDataTransformer` pipeline (group-by, pivot, derive node rows from
edge labels) — that is the Sankey follow-up exercise.

### Why `$data` per panel instead of shared `$data` on EmbeddedScene?

The two panels need different datasources (Tempo and Prometheus). Attaching
`SceneQueryRunner` directly to each `VizPanel` via `.setData()` keeps the queries
independent and avoids the need for multiple `refId` handling on a shared runner.

## QueryVariable mechanics

```
allValue: '.*'
```

When the user selects "All", Grafana interpolates `$tenant` as `.*`. The Prometheus
query becomes:

```promql
sum by (client, server, tenant_id) (
  rate(traces_service_graph_request_total{tenant_id=~".*"}[5m])
)
```

which matches every tenant. Selecting `acme` narrows to `tenant_id=~"acme"`.

## Plugin loading (unsigned)

The plugin is unsigned (local dev build). Grafana allows it via:

```yaml
GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS: otel-mq-app
```

The `dist/` directory is volume-mounted into the Grafana container:

```yaml
volumes:
  - ./otel-mq-app/dist:/var/lib/grafana/plugins/otel-mq-app
```

After changing plugin source, run `npm run build` inside
`otel-mq-app/` and restart the Grafana container.

## Sending traffic

```bash
# Single tenant
curl -X POST http://localhost:8080/send -H 'X-Tenant-ID: acme' -H 'X-User-ID: user1'

# Generate data for multiple tenants
for t in acme beta gamma; do
  for i in $(seq 1 10); do
    curl -s -X POST http://localhost:8080/send -H "X-Tenant-ID: $t" -H "X-User-ID: user$i"
  done
done
```

Service graph metrics appear in Prometheus within ~30 s after spans are received
by Tempo (the metrics_generator flush interval).
