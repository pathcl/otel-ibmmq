# Caching the Service Graph

Notes from design discussion. Stack: Mimir, Grafana, Tempo, Linux.

The service map is built with ECharts Sankey, powered by Prometheus queries against
Tempo's `metrics_generator` (servicegraph processor + spanmetrics processor). A later
migration to the OpenTelemetry servicegraph connector is planned but doesn't affect
the caching strategy.

---

## Q: How do we cache service graph relations to reduce backend load and stay available when backends fail?

Three layers, each solving a different part of the problem.

### Layer 1: Mimir recording rules (biggest impact on backend load)

The servicegraph metrics (`traces_service_graph_request_total`, `_failed_total`,
`_duration_seconds_bucket`) are high-cardinality. Pre-compute the edges as recording rules:

```yaml
groups:
  - name: servicegraph_cache
    interval: 1m
    rules:
      - record: service_graph:edges:rate5m
        expr: |
          sum by (client, server) (
            rate(traces_service_graph_request_total[5m])
          )
      - record: service_graph:error_rate:rate5m
        expr: |
          sum by (client, server) (
            rate(traces_service_graph_request_failed_total[5m])
          )
```

The Sankey query then reads `service_graph:edges:rate5m` — a cheap point lookup instead
of a range aggregation over raw spans. Also survives Tempo being down since the recorded
metric persists in Mimir.

### Layer 2: Mimir query-frontend caching

Mimir's query-frontend has built-in result caching. Add memcached or Redis:

```yaml
# mimir config
frontend:
  cache_results: true
  results_cache:
    backend: memcached
    memcached:
      addresses: dns+memcached:11211
```

Transparent — no plugin changes needed.

### Layer 3: `RuntimeDataSource` in the Scenes plugin (resilience)

`RuntimeDataSource` lets you implement a custom datasource in TypeScript that falls back
to stale data when backends are unavailable:

```ts
import { RuntimeDataSource } from '@grafana/scenes';

class CachedServiceMapDataSource extends RuntimeDataSource {
  async query(request: DataQueryRequest): Promise<DataQueryResponse> {
    try {
      const result = await queryMimir(request);
      localStorage.setItem('servicemap_cache', JSON.stringify(serialize(result)));
      return result;
    } catch {
      const cached = localStorage.getItem('servicemap_cache');
      if (cached) {
        return deserialize(JSON.parse(cached)); // stale data, backends down
      }
      throw new Error('No cached data available');
    }
  }
}
```

Wire it into the scene instead of a direct Prometheus datasource.

### Summary

| Goal | Best tool |
|------|-----------|
| Reduce backend load | Recording rules in Mimir |
| Survive Tempo failure | Recording rules (metric persists in Mimir after Tempo dies) |
| Survive Mimir failure | `RuntimeDataSource` + localStorage in the plugin |
| Transparent caching | Mimir query-frontend + memcached |

Start with recording rules — covers most of the goals and survives the OTel connector
switch (only the recording rule expression changes, not the Sankey query).

---

## Q: What if we added extra dimensions to the servicegraph processor: endpoint, tenant, country? Would recording rules still work?

They still work, but extra dimensions introduce a **cardinality explosion risk**.

### The problem

A naive rule preserving all dimensions:

```promql
sum by (client, server, endpoint, tenant, country) (
  rate(traces_service_graph_request_total[5m])
)
```

With realistic numbers — 50 services × 200 endpoints × 30 tenants × 100 countries —
you're looking at ~30M series. Mimir will struggle and the caching benefit disappears.

`endpoint` is the most dangerous label. REST APIs easily generate thousands of unique
paths per service pair.

### What actually works: tiered recording rules

Create separate rules per view rather than one rule with all dimensions:

```yaml
groups:
  - name: servicegraph
    interval: 1m
    rules:
      # top-level servicemap — no extra dimensions
      - record: service_graph:edges:rate5m
        expr: |
          sum by (client, server) (
            rate(traces_service_graph_request_total[5m])
          )

      # per-tenant breakdown — tenants are typically low cardinality
      - record: service_graph:edges_by_tenant:rate5m
        expr: |
          sum by (client, server, tenant) (
            rate(traces_service_graph_request_total[5m])
          )

      # per-country — drop endpoint, it's too high cardinality here
      - record: service_graph:edges_by_country:rate5m
        expr: |
          sum by (client, server, country) (
            rate(traces_service_graph_request_total[5m])
          )
```

The Sankey queries use the appropriate pre-aggregated metric per view. Never query the
raw metric from the plugin.

### `endpoint` deserves special treatment

Consider whether you need endpoint-level edges in the top-level Sankey at all, or if a
drilldown page (click on a service pair → see endpoint breakdown) is better. That way
the top-level Sankey stays cheap and you only pay the endpoint cardinality cost on demand.

If endpoint must be included, cap it at Tempo's side before it hits Mimir:

```yaml
# tempo metrics_generator config
service_graphs:
  dimensions: [tenant, country]   # omit endpoint here
```

Handle endpoint-level data separately via spanmetrics (which already breaks down by
operation/span name) rather than servicegraph.

### Dimension cardinality guide

| Dimension | Cardinality risk | Approach |
|-----------|-----------------|----------|
| `tenant` | Low (tens–hundreds) | Include in recording rule |
| `country` | Medium (~250 max) | Include in recording rule |
| `endpoint` | High (thousands) | Drilldown only, or cap in Tempo config |

The tiered approach also maps cleanly to the `RuntimeDataSource` fallback cache in the
plugin — each view caches its own pre-aggregated metric independently.
