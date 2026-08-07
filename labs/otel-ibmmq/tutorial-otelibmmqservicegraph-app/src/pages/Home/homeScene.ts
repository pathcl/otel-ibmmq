import {
  EmbeddedScene,
  PanelBuilders,
  QueryVariable,
  SceneControlsSpacer,
  SceneFlexItem,
  SceneFlexLayout,
  SceneQueryRunner,
  SceneRefreshPicker,
  SceneTimePicker,
  SceneTimeRange,
  SceneVariableSet,
  VariableValueSelectors,
} from '@grafana/scenes';

const PROMETHEUS = { type: 'prometheus', uid: 'prometheus' };
const TEMPO = { type: 'tempo', uid: 'tempo' };

export function homeScene() {
  const timeRange = new SceneTimeRange({ from: 'now-1h', to: 'now' });

  // QueryVariable: populates from distinct tenant_id label values produced by
  // Tempo metrics_generator → Prometheus. "All tenants" is the default.
  const tenantVariable = new QueryVariable({
    name: 'tenant',
    label: 'Tenant',
    datasource: PROMETHEUS,
    query: 'label_values(traces_service_graph_request_total, tenant_id)',
    includeAll: true,
    defaultToAll: true,
    allValue: '.*',
  });

  // Tempo's built-in serviceMap query type queries Prometheus under the hood
  // (using the serviceMap.datasourceUid configured in the datasource) and
  // returns pre-formatted nodes + edges frames that the nodeGraph panel consumes
  // directly — no SceneDataTransformer needed.
  const serviceMapRunner = new SceneQueryRunner({
    datasource: TEMPO,
    queries: [{ refId: 'A', queryType: 'serviceMap' }],
  });

  // Per-tenant request rate, filtered by the $tenant variable.
  // The variable interpolates as a regex so "All" becomes ".*".
  const trafficRunner = new SceneQueryRunner({
    datasource: PROMETHEUS,
    queries: [
      {
        refId: 'A',
        expr: 'sum by (client, server, tenant_id) (rate(traces_service_graph_request_total{tenant_id=~"$tenant"}[5m]))',
        legendFormat: '{{client}} → {{server}} [{{tenant_id}}]',
      },
    ],
  });

  return new EmbeddedScene({
    $timeRange: timeRange,
    $variables: new SceneVariableSet({ variables: [tenantVariable] }),
    body: new SceneFlexLayout({
      direction: 'column',
      children: [
        new SceneFlexItem({
          minHeight: 500,
          body: PanelBuilders.nodegraph()
            .setTitle('Service Graph')
            .setData(serviceMapRunner)
            .build(),
        }),
        new SceneFlexItem({
          minHeight: 300,
          body: PanelBuilders.timeseries()
            .setTitle('Request Rate — $tenant')
            .setData(trafficRunner)
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
