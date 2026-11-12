{{flutter_js}}
{{flutter_build_config}}
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
