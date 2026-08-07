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

  return new EmbeddedScene({
    $timeRange: timeRange,
    $variables: new SceneVariableSet({ variables: [tenantVariable] }),
    body: new SceneFlexLayout({
      direction: 'column',
      children: [
        // Row 1: summary stats side by side
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
        // Row 2: request rate through each pipeline edge, filtered by tenant
        new SceneFlexItem({
          minHeight: 250,
          body: PanelBuilders.timeseries()
            .setTitle('Request rate by pipeline stage — $tenant')
            .setData(new SceneQueryRunner({
              datasource: PROMETHEUS,
              queries: [{
                refId: 'A',
                expr: 'sum by (client, server) (rate(traces_service_graph_request_total{tenant_id=~"$tenant"}[5m]))',
                legendFormat: '{{client}} → {{server}}',
              }],
            }))
            .build(),
        }),
        // Row 3: recent traces for this tenant, searchable in Tempo
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
