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
import { DataFrame, DataTransformContext, FieldType, MutableDataFrame } from '@grafana/data';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';

const PROMETHEUS = { type: 'prometheus', uid: 'prometheus' };
const TEMPO = { type: 'tempo', uid: 'tempo' };

// ── node graph transformation ─────────────────────────────────────────────────
//
// refId 'A' = traces_service_graph_request_total         (all requests)
// refId 'B' = traces_service_graph_request_failed_total  (failed requests)
//
// Prometheus instant queries return one DataFrame per time series. Labels live
// on the numeric field:  frame.fields[1].labels = { client, server, tenant_id }
//                        frame.fields[1].values[0] = rate value
//
// Nodes get arc__success / arc__failed (0-1 proportions, sum=1) to render a
// green/red arc ring, plus detail__* rows shown in the click-side-panel.

function buildNodeGraphFrames(frames: DataFrame[]): DataFrame[] {
  const totalFrames = frames.filter((f) => f.refId === 'A' && f.length > 0);
  const failedFrames = frames.filter((f) => f.refId === 'B' && f.length > 0);

  if (totalFrames.length === 0) {
    return [];
  }

  // edge key `${client}|${server}` → rate (req/s)
  const totalByEdge = new Map<string, number>();
  const failedByEdge = new Map<string, number>();
  const services = new Set<string>();

  for (const frame of totalFrames) {
    const valueField = frame.fields.find((f) => f.type === FieldType.number);
    if (!valueField?.labels) {
      continue;
    }
    const client = valueField.labels['client'];
    const server = valueField.labels['server'];
    if (!client || !server) {
      continue;
    }
    services.add(client);
    services.add(server);
    totalByEdge.set(`${client}|${server}`, Number(valueField.values[0]) || 0);
  }

  for (const frame of failedFrames) {
    const valueField = frame.fields.find((f) => f.type === FieldType.number);
    if (!valueField?.labels) {
      continue;
    }
    const client = valueField.labels['client'];
    const server = valueField.labels['server'];
    if (!client || !server) {
      continue;
    }
    failedByEdge.set(`${client}|${server}`, Number(valueField.values[0]) || 0);
  }

  if (totalByEdge.size === 0) {
    return [];
  }

  // Aggregate incoming rates per node (nodes without inbound edges get 0)
  const incomingTotal = new Map<string, number>();
  const incomingFailed = new Map<string, number>();
  for (const [key, rate] of totalByEdge) {
    const server = key.split('|')[1];
    incomingTotal.set(server, (incomingTotal.get(server) || 0) + rate);
  }
  for (const [key, rate] of failedByEdge) {
    const server = key.split('|')[1];
    incomingFailed.set(server, (incomingFailed.get(server) || 0) + rate);
  }

  const nodesFrame = new MutableDataFrame({
    name: 'nodes',
    meta: { preferredVisualisationType: 'nodeGraph' },
    fields: [
      { name: 'id',               type: FieldType.string },
      { name: 'title',            type: FieldType.string },
      { name: 'mainStat',         type: FieldType.number, config: { unit: 'reqps',       displayName: 'req/s in'    } },
      { name: 'secondaryStat',    type: FieldType.number, config: { unit: 'percentunit', displayName: 'error %'     } },
      { name: 'arc__success',     type: FieldType.number, config: { color: { fixedColor: 'green', mode: 'fixed' }, displayName: 'Success' } },
      { name: 'arc__failed',      type: FieldType.number, config: { color: { fixedColor: 'red',   mode: 'fixed' }, displayName: 'Failed'  } },
      { name: 'detail__req_s',    type: FieldType.number, config: { unit: 'reqps',       displayName: 'Total req/s' } },
      { name: 'detail__errors_s', type: FieldType.number, config: { unit: 'reqps',       displayName: 'Errors/s'   } },
    ],
  });

  for (const svc of services) {
    const total = incomingTotal.get(svc) || 0;
    const failed = incomingFailed.get(svc) || 0;
    const errorRate = total > 0 ? failed / total : 0;
    nodesFrame.add({
      id: svc,
      title: svc,
      mainStat: total,
      secondaryStat: errorRate,
      arc__success: 1 - errorRate,
      arc__failed: errorRate,
      detail__req_s: total,
      detail__errors_s: failed,
    });
  }

  const edgesFrame = new MutableDataFrame({
    name: 'edges',
    meta: { preferredVisualisationType: 'nodeGraph' },
    fields: [
      { name: 'id',            type: FieldType.string },
      { name: 'source',        type: FieldType.string },
      { name: 'target',        type: FieldType.string },
      { name: 'mainStat',      type: FieldType.number, config: { unit: 'reqps',       displayName: 'req/s'   } },
      { name: 'secondaryStat', type: FieldType.number, config: { unit: 'percentunit', displayName: 'error %' } },
    ],
  });

  for (const [key, total] of totalByEdge) {
    const [client, server] = key.split('|');
    const failed = failedByEdge.get(key) || 0;
    const errorRate = total > 0 ? failed / total : 0;
    edgesFrame.add({
      id: `${client}→${server}`,
      source: client,
      target: server,
      mainStat: total,
      secondaryStat: errorRate,
    });
  }

  return [nodesFrame, edgesFrame];
}

// ── scene ─────────────────────────────────────────────────────────────────────

export function tenantDebugScene() {
  const timeRange = new SceneTimeRange({ from: 'now-1h', to: 'now' });

  const tenantVariable = new QueryVariable({
    name: 'tenant',
    label: 'Tenant',
    datasource: PROMETHEUS,
    query: 'label_values(traces_service_graph_request_total, tenant_id)',
    includeAll: true,
    defaultToAll: true,
    allValue: '.*',
  });

  // Two instant queries: A = total rate, B = failed rate.
  // instant: true → one frame per series with labels on the numeric field.
  const serviceGraphQueryRunner = new SceneQueryRunner({
    datasource: PROMETHEUS,
    queries: [
      {
        refId: 'A',
        expr: 'sum by (client, server) (rate(traces_service_graph_request_total{tenant_id=~"$tenant"}[$__range]))',
        instant: true,
      },
      {
        refId: 'B',
        expr: 'sum by (client, server) (rate(traces_service_graph_request_failed_total{tenant_id=~"$tenant"}[$__range]))',
        instant: true,
      },
    ],
  });

  const tenantServiceGraph = new SceneDataTransformer({
    $data: serviceGraphQueryRunner,
    transformations: [
      { operator: (_ctx: DataTransformContext) => (source: Observable<DataFrame[]>) => source.pipe(map((frames) => buildNodeGraphFrames(frames))) },
    ],
  });

  return new EmbeddedScene({
    $timeRange: timeRange,
    $variables: new SceneVariableSet({ variables: [tenantVariable] }),
    body: new SceneFlexLayout({
      direction: 'column',
      children: [
        new SceneFlexItem({
          minHeight: 450,
          body: PanelBuilders.nodegraph()
            .setTitle('Service Graph — $tenant')
            .setData(tenantServiceGraph)
            .build(),
        }),
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
        new SceneFlexItem({
          minHeight: 400,
          body: PanelBuilders.traces()
            .setTitle('Traces — $tenant')
            .setData(new SceneQueryRunner({
              datasource: TEMPO,
              queries: [{
                refId: 'A',
                queryType: 'traceql',
                query: '{.tenant.id =~ "$tenant"}',
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
