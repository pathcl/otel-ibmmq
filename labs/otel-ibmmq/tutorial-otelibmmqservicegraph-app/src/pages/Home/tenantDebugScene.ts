import {
  EmbeddedScene,
  PanelBuilders,
  QueryVariable,
  SceneControlsSpacer,
  SceneDataTransformer,
  SceneFlexItem,
  SceneFlexLayout,
  SceneQueryRunner,
  SceneRefreshPicker,
  SceneTimePicker,
  SceneTimeRange,
  SceneVariableSet,
  VariableValueSelectors,
} from '@grafana/scenes';
import { DataFrame, FieldType, MutableDataFrame } from '@grafana/data';
import { map } from 'rxjs/operators';

const PROMETHEUS = { type: 'prometheus', uid: 'prometheus' };
const TEMPO = { type: 'tempo', uid: 'tempo' };

// ── node graph transformation ─────────────────────────────────────────────────
//
// The Tempo serviceMap query ignores variables — it always returns all edges.
// This transformer queries Prometheus directly with {tenant_id=~"$tenant"} and
// reshapes the result into the two frames the nodeGraph panel expects:
//   • nodes frame:  id, title, mainStat
//   • edges frame:  id, source, target, mainStat
//
// Input (after Prometheus instant+table query):
//   refId A — traces_service_graph_request_total  → success rates per (client,server)
//   refId B — traces_service_graph_failed_request_total → error rates per (client,server)

function buildNodeGraphFrames(frames: DataFrame[]): DataFrame[] {
  const successFrame = frames.find((f) => f.refId === 'A');
  if (!successFrame || successFrame.length === 0) {
    return [];
  }
  const failedFrame = frames.find((f) => f.refId === 'B');

  const clientField  = successFrame.fields.find((f) => f.name === 'client');
  const serverField  = successFrame.fields.find((f) => f.name === 'server');
  const valueField   = successFrame.fields.find((f) => f.name === 'Value');
  if (!clientField || !serverField || !valueField) {
    return [];
  }

  // Build a map of failed rates keyed by "client→server"
  const failedRates = new Map<string, number>();
  if (failedFrame) {
    const fc = failedFrame.fields.find((f) => f.name === 'client');
    const fs = failedFrame.fields.find((f) => f.name === 'server');
    const fv = failedFrame.fields.find((f) => f.name === 'Value');
    if (fc && fs && fv) {
      for (let i = 0; i < failedFrame.length; i++) {
        const key = `${fc.values[i]}→${fs.values[i]}`;
        failedRates.set(key, Number(fv.values[i]) || 0);
      }
    }
  }

  // Collect unique services and per-edge rates
  const services = new Set<string>();
  type Edge = { client: string; server: string; rate: number; failedRate: number };
  const edges: Edge[] = [];

  for (let i = 0; i < successFrame.length; i++) {
    const client     = String(clientField.values[i]);
    const server     = String(serverField.values[i]);
    const rate       = Number(valueField.values[i]) || 0;
    const failedRate = failedRates.get(`${client}→${server}`) || 0;
    services.add(client);
    services.add(server);
    edges.push({ client, server, rate, failedRate });
  }

  // Aggregate incoming rate per service for the node's mainStat
  const incomingRate = new Map<string, number>();
  for (const e of edges) {
    incomingRate.set(e.server, (incomingRate.get(e.server) || 0) + e.rate);
  }

  // Nodes frame
  const nodesFrame = new MutableDataFrame({
    name: 'nodes',
    meta: { preferredVisualisationType: 'nodeGraph' },
    fields: [
      { name: 'id',       type: FieldType.string },
      { name: 'title',    type: FieldType.string },
      { name: 'mainStat', type: FieldType.number, config: { unit: 'reqps', displayName: 'req/s in' } },
    ],
  });
  for (const svc of services) {
    nodesFrame.add({ id: svc, title: svc, mainStat: incomingRate.get(svc) ?? 0 });
  }

  // Edges frame
  const edgesFrame = new MutableDataFrame({
    name: 'edges',
    meta: { preferredVisualisationType: 'nodeGraph' },
    fields: [
      { name: 'id',       type: FieldType.string },
      { name: 'source',   type: FieldType.string },
      { name: 'target',   type: FieldType.string },
      { name: 'mainStat', type: FieldType.number, config: { unit: 'reqps', displayName: 'req/s' } },
    ],
  });
  for (const e of edges) {
    edgesFrame.add({ id: `${e.client}→${e.server}`, source: e.client, target: e.server, mainStat: e.rate });
  }

  return [nodesFrame, edgesFrame];
}

// ── scene ─────────────────────────────────────────────────────────────────────

export function tenantDebugScene() {
  const timeRange = new SceneTimeRange({ from: 'now-1h', to: 'now' });

  // Same variable name as the service graph tab so URL sync keeps the selection
  // when switching between tabs.
  const tenantVariable = new QueryVariable({
    name: 'tenant',
    label: 'Tenant',
    datasource: PROMETHEUS,
    query: 'label_values(traces_service_graph_request_total, tenant_id)',
    includeAll: true,
    defaultToAll: true,
    allValue: '.*',
  });

  // Instant + table format gives one row per (client, server) pair with label
  // columns — the shape buildNodeGraphFrames() expects.
  const serviceGraphQueryRunner = new SceneQueryRunner({
    datasource: PROMETHEUS,
    queries: [
      {
        refId: 'A',
        expr: 'sum by (client, server) (rate(traces_service_graph_request_total{tenant_id=~"$tenant"}[5m]))',
        instant: true,
        format: 'table',
      },
      {
        refId: 'B',
        expr: 'sum by (client, server) (rate(traces_service_graph_failed_request_total{tenant_id=~"$tenant"}[5m]))',
        instant: true,
        format: 'table',
      },
    ],
  });

  const tenantServiceGraph = new SceneDataTransformer({
    $data: serviceGraphQueryRunner,
    transformations: [
      { operator: (source) => source.pipe(map((frames) => buildNodeGraphFrames(frames))) },
    ],
  });

  return new EmbeddedScene({
    $timeRange: timeRange,
    $variables: new SceneVariableSet({ variables: [tenantVariable] }),
    body: new SceneFlexLayout({
      direction: 'column',
      children: [
        // Tenant-filtered node graph — the whole point of this tab
        new SceneFlexItem({
          minHeight: 450,
          body: PanelBuilders.nodegraph()
            .setTitle('Service Graph — $tenant')
            .setData(tenantServiceGraph)
            .build(),
        }),
        // Summary stats
        new SceneFlexItem({
          minHeight: 100,
          body: new SceneFlexLayout({
            direction: 'row',
            children: [
              new SceneFlexItem({
                body: PanelBuilders.stat()
                  .setTitle('Messages Processed')
                  .setData(new SceneQueryRunner({
                    datasource: PROMETHEUS,
                    queries: [{
                      refId: 'A',
                      expr: 'sum(increase(messages_processed_total{tenant_id=~"$tenant"}[$__range]))',
                      legendFormat: 'processed',
                    }],
                  }))
                  .build(),
              }),
              new SceneFlexItem({
                body: PanelBuilders.stat()
                  .setTitle('Messages Rejected (DLQ)')
                  .setData(new SceneQueryRunner({
                    datasource: PROMETHEUS,
                    queries: [{
                      refId: 'A',
                      expr: 'sum(increase(messages_rejected_total{tenant_id=~"$tenant"}[$__range]))',
                      legendFormat: 'rejected',
                    }],
                  }))
                  .build(),
              }),
            ],
          }),
        }),
        // Traces for this tenant
        new SceneFlexItem({
          minHeight: 400,
          body: PanelBuilders.traces()
            .setTitle('Traces — $tenant')
            .setData(new SceneQueryRunner({
              datasource: TEMPO,
              queries: [{
                refId: 'A',
                queryType: 'traceql',
                query: '{span["tenant.id"]=~"$tenant"}',
                limit: 20,
              }],
            }))
            .build(),
        }),
      ],
    }),
    controls: [
      new VariableValueSelectors({}),
      new SceneControlsSpacer(),
      new SceneTimePicker({ isOnCanvas: true }),
      new SceneRefreshPicker({ intervals: ['5s', '30s', '1m'], isOnCanvas: true }),
    ],
  });
}
