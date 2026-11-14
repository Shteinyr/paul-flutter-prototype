// Inlined by build_live.sh before the Flutter engine starts. Only the anonymous
// public profiles request is allowed here; never read browser Auth storage.
(() => {
  const settings = /* PAUL_PUBLIC_PREVIEW_SETTINGS */ null;
  if (!settings || typeof settings.url !== 'string' || !settings.url ||
      typeof settings.key !== 'string' || !settings.key) return;
  if (new URL(location.href).searchParams.get('auth') === 'callback') return;
  let endpoint;
  try {
    const base = new URL(settings.url);
    if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) return;
    endpoint = new URL('/functions/v1/public-preview', base).href;
  } catch (_) { return; }
  let claimed = false;
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), 20000);
  const pending = fetch(endpoint, {
    method: 'POST',
    headers: {apikey: settings.key, 'Content-Type': 'application/json'},
    credentials: 'omit',
    cache: 'no-store',
    redirect: 'error',
    referrerPolicy: 'no-referrer',
    signal: abort.signal,
    body: JSON.stringify({action: 'profiles', query: '', kind: 'all'}),
  }).then(async response => {
    if (!response.ok) return null;
    const text = await response.text();
    if (text.length > 1048576) return null;
    const data = JSON.parse(text);
    if (data.query !== '' || !Array.isArray(data.profiles)) return null;
    return {data, receivedAt: Date.now()};
  }).catch(() => null).finally(() => clearTimeout(timer));
  globalThis.paulPublicPreviewBootstrap = Object.freeze({
    async take(expectedEndpoint, expectedKey) {
      if (claimed || expectedEndpoint !== endpoint || expectedKey !== settings.key) return 'null';
      claimed = true;
      const result = await pending;
      // Signed photos have a 60s TTL. Do not reuse a response after a long engine
      // download, and never retain this snapshot across reloads or in storage.
      if (!result || Date.now() - result.receivedAt > 15000) return 'null';
      return JSON.stringify(result.data);
    },
  });
})();
