import { SceneAppPage } from '@grafana/scenes';
import { homeScene } from './homeScene';
import { prefixRoute } from '../../utils/utils.routing';
import { ROUTES } from '../../constants';

export const homePage = new SceneAppPage({
  title: 'Service Graph',
  url: prefixRoute(ROUTES.Home),
  routePath: ROUTES.Home,
  subTitle: 'Baggage propagation across gateway → processor, filterable by tenant.',
  getScene: () => homeScene(),
});
