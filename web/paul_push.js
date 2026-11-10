/* Browser-only push bridge. No authentication credentials or profile data persist here. */
(() => {
  'use strict';
  const workerUrl = new URL('paul_push_worker.js', document.baseURI);
  const scope = new URL('.', workerUrl).href;
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  let identity = null;
  let session = null;
  let generation = 0;
  let listener = null;
  let pending = null;

  function supported() {
    return window.isSecureContext && window.top === window &&
      'Notification' in window && 'PushManager' in window &&
      'serviceWorker' in navigator && 'locks' in navigator && 'indexedDB' in window && !!window.crypto?.subtle;
  }
  function record(change) {
    return new Promise((resolve, reject) => {
      const request = indexedDB.open('paul-push-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('binding');
      request.onerror = () => reject(new Error('storage_unavailable'));
      request.onsuccess = () => {
        const db = request.result;
        const tx = db.transaction('binding', change ? 'readwrite' : 'readonly');
        const store = tx.objectStore('binding');
        const read = store.get('current');
        let result;
        read.onsuccess = () => {
          result = read.result || null;
          if (change) {
            try {
              result = change(result);
              store.put(result, 'current');
            } catch (error) { tx.abort(); reject(error); }
          }
        };
        tx.oncomplete = () => { db.close(); resolve(result); };
        tx.onerror = () => { db.close(); reject(new Error('storage_unavailable')); };
        tx.onabort = () => { db.close(); reject(new Error('storage_unavailable')); };
      };
    });
  }
  async function registration(create = false) {
    const current = await navigator.serviceWorker.getRegistration(scope);
    if (current?.active?.scriptURL === workerUrl.href && !create) return current;
    if (!create) return null;
    const registered = await navigator.serviceWorker.register(workerUrl.href, {scope, updateViaCache: 'none'});
    if (registered.active?.scriptURL === workerUrl.href && !registered.installing && !registered.waiting) return registered;
    await new Promise((resolve, reject) => {
      const worker = registered.installing || registered.waiting;
      if (!worker) { reject(new Error('worker_unavailable')); return; }
      const timer = setTimeout(() => reject(new Error('worker_unavailable')), 15000);
      worker.addEventListener('statechange', () => {
        if (worker.state === 'activated') { clearTimeout(timer); resolve(); }
        if (worker.state === 'redundant') { clearTimeout(timer); reject(new Error('worker_unavailable')); }
      });
    });
    return registered;
  }
  function current(userId, version) {
    if (identity !== userId || generation !== version) throw new Error('identity_changed');
  }
  function keyBytes(key) {
    const raw = atob(key.replace(/-/g, '+').replace(/_/g, '/'));
    const bytes = Uint8Array.from(raw, c => c.charCodeAt(0));
    if (bytes.length !== 65 || bytes[0] !== 4) throw new Error('invalid_configuration');
    return bytes;
  }
  async function fingerprint(subscription) {
    const value = subscription.toJSON();
    const source = JSON.stringify([value.endpoint, value.expirationTime, value.keys?.p256dh, value.keys?.auth]);
    const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(source));
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('');
  }
  async function inspect() {
    if (!supported()) return {supported: false, permission: 'unsupported'};
    const reg = await registration();
    const subscription = reg ? await reg.pushManager.getSubscription() : null;
    let binding = await record();
    if (subscription && binding?.user_id === identity && binding?.session_id === session) {
      const hash = await fingerprint(subscription);
      if (binding.subscription_hash !== hash) {
        const expected = binding;
        binding = await record(current => current?.binding_id === expected.binding_id &&
          current?.session_id === expected.session_id ? {...current, active: false} : current);
      }
    }
    return {supported: true, permission: Notification.permission,
      binding: subscription && binding?.user_id === identity && binding?.session_id === session ? binding : null};
  }
  async function clear(userId, expectedSession, expectedBinding = null) {
    if (!supported() || !userId) return null;
    const revision = crypto.randomUUID();
    let removed = null;
    await record(old => {
      if (old?.user_id !== userId || old?.session_id !== expectedSession ||
          (expectedBinding && old.binding_id !== expectedBinding)) return old;
      removed = old;
      return {user_id: null, binding_id: null, active: false, revision};
    });
    if (!removed) return null;
    await navigator.locks.request('paul-push-binding', async () => {
      const reg = await registration();
      const notifications = reg ? await reg.getNotifications() : [];
      for (const notification of notifications) {
        if (notification.data?.recipient_user_id === userId) notification.close();
      }
      if ((await record())?.revision !== revision) return;
      const subscription = reg ? await reg.pushManager.getSubscription() : null;
      if (subscription && !await subscription.unsubscribe()) throw new Error('unsubscribe_failed');
    });
    return removed;
  }
  async function prepare(userId, publicKey) {
    const version = generation;
    current(userId, version);
    return navigator.locks.request('paul-push-binding', async () => {
      current(userId, version);
      const reg = await registration(true);
      current(userId, version);
      let binding = await record();
      let expectedRevision = binding?.revision;
      let subscription = await reg.pushManager.getSubscription();
      const priorHash = subscription ? await fingerprint(subscription) : null;
      if (!subscription || binding?.user_id !== userId || binding?.session_id !== session || binding?.public_key !== publicKey || binding?.subscription_hash !== priorHash) {
        // A new identity receives a fresh endpoint, never the prior account's endpoint.
        const cleared = await record(() => ({user_id: null, active: false, revision: crypto.randomUUID()}));
        expectedRevision = cleared.revision;
        if (subscription && !await subscription.unsubscribe()) throw new Error('unsubscribe_failed');
        subscription = null;
        binding = null;
      }
      current(userId, version);
      subscription ||= await reg.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: keyBytes(publicKey)});
      current(userId, version);
      const hash = await fingerprint(subscription);
      binding ||= {user_id: userId, session_id: session, binding_id: crypto.randomUUID(), public_key: publicKey,
        active: false, subscription_hash: hash, revision: crypto.randomUUID()};
      await record(old => {
        current(userId, version);
        if (old?.revision !== expectedRevision) throw new Error('identity_changed');
        return binding;
      });
      return {binding_id: binding.binding_id, subscription: subscription.toJSON()};
    });
  }
  async function commit(userId, bindingId, canonicalId) {
    const version = generation;
    current(userId, version);
    let committed = false;
    await record(old => {
      current(userId, version);
      if (old?.user_id !== userId || old?.binding_id !== bindingId) return old;
      committed = true;
      return {...old, binding_id: canonicalId, active: true};
    });
    if (!committed) throw new Error('identity_changed');
  }
  function route(value) {
    if (!value || value.type !== 'paul.push.click' || value.version !== 1 ||
        !uuid.test(value.recipient_user_id) || !uuid.test(value.binding_id) ||
        !uuid.test(value.delivery_id)) return null;
    return {type: value.type, version: 1, recipient_user_id: value.recipient_user_id,
      binding_id: value.binding_id, delivery_id: value.delivery_id};
  }
  try { navigator.serviceWorker?.addEventListener('message', event => {
    if (!event.source || event.source.scriptURL !== workerUrl.href) return;
    const click = route(event.data);
    if (click) { pending = click; listener?.(JSON.stringify(click)); }
  }); } catch (_) { /* Restricted browser contexts keep the guest entry usable. */ }
  window.paulPush = {
    inspect: () => inspect().then(JSON.stringify),
    permission: () => Notification.requestPermission(),
    identity: async (userId, sessionId) => {
      const old = identity;
      const oldSession = session;
      identity = userId || null;
      session = sessionId || null;
      generation++;
      if (pending?.recipient_user_id !== identity) pending = null;
      if (old && (old !== identity || oldSession !== session)) await clear(old, oldSession);
      // Cold-start account changes also invalidate the durable worker binding.
      if (supported()) {
        const saved = await record();
        if (saved?.user_id && (saved.user_id !== identity || saved.session_id !== session)) await clear(saved.user_id, saved.session_id, saved.binding_id);
        if (identity && session) await registration(true);
      }
    },
    prepare: (userId, publicKey) => prepare(userId, publicKey).then(JSON.stringify),
    commit,
    clear: (userId, sessionId) => { generation++; return clear(userId, sessionId).then(JSON.stringify); },
    listen: callback => { listener = callback; if (pending) callback(JSON.stringify(pending)); },
    takeClick: () => {
      const query = new URL(location.href);
      const click = route({type: 'paul.push.click', version: 1,
        recipient_user_id: query.searchParams.get('push_user'),
        binding_id: query.searchParams.get('push_binding'), delivery_id: query.searchParams.get('push_event')});
      if (click) {
        for (const name of ['push_user', 'push_binding', 'push_event']) query.searchParams.delete(name);
        history.replaceState(null, '', query);
      }
      const result = click || pending;
      pending = null;
      return JSON.stringify(result);
    },
  };
})();
