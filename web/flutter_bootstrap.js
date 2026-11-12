{{flutter_js}}
{{flutter_build_config}}
// Release builds bundle this exact default font. Start it alongside the runtime
// instead of discovering it only after main.dart.js and FontManifest have loaded.
if (_flutter.buildConfig.useLocalCanvasKit) {
  const fallback = document.createElement('link');
  fallback.rel = 'preload';
  fallback.as = 'fetch';
  fallback.href = new URL('assets/fonts/fallback/Roboto-Regular.ttf', document.baseURI).href;
  fallback.crossOrigin = 'anonymous';
  fallback.fetchPriority = 'low';
  document.head.append(fallback);
}
// The inline loader starts engine/entrypoint downloads immediately. The deferred
// push bridge must still finish before Dart accesses it during runApp.
const paulDocumentReady = document.readyState === 'loading'
  ? new Promise(resolve => document.addEventListener('DOMContentLoaded', resolve, {once: true}))
  : Promise.resolve();
_flutter.loader.load({
  onEntrypointLoaded: async function(engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    await paulDocumentReady;
    await appRunner.runApp();
    document.getElementById('loading')?.remove();
  }
});
