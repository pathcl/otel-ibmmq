import React from 'react';
import { SceneApp, useSceneApp } from '@grafana/scenes';
import { AppRootProps } from '@grafana/data';
import { homePage } from '../../pages/Home/homePage';
import { PluginPropsContext } from '../../utils/utils.plugin';

function getSceneApp() {
  return new SceneApp({
    pages: [homePage],
    urlSyncOptions: {
      updateUrlOnInit: true,
      createBrowserHistorySteps: true,
    },
  });
}

function AppWithScenes() {
  const scene = useSceneApp(getSceneApp);
  return <scene.Component model={scene} />;
}

function App(props: AppRootProps) {
  return (
    <PluginPropsContext.Provider value={props}>
      <AppWithScenes />
    </PluginPropsContext.Provider>
  );
}

export default App;
