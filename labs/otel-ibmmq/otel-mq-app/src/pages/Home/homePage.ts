import { SceneAppPage } from '@grafana/scenes';
import { homeScene } from './homeScene';
import { tenantDebugScene } from './tenantDebugScene';
import { prefixRoute } from '../../utils/utils.routing';
import { ROUTES } from '../../constants';

export const homePage = new SceneAppPage({
  title: 'IBM MQ Lab',
  url: prefixRoute(ROUTES.Home),
  routePath: `${ROUTES.Home}/*`,
  hideFromBreadcrumbs: true,
  getScene: () => homeScene(),
  tabs: [
    new SceneAppPage({
      title: 'Service Graph',
      url: prefixRoute(ROUTES.Home),
      routePath: '/',
      getScene: () => homeScene(),
    }),
    new SceneAppPage({
      title: 'Tenant Debug',
      url: prefixRoute(ROUTES.TenantDebug),
      routePath: '/tenant-debug',
      getScene: () => tenantDebugScene(),
    }),
  ],
});
