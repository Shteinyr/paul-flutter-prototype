'use strict';
const dedupLifetimeMs = 26 * 60 * 60 * 1000;
const dedupCapacity = 8192;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
          try { result = change(result); store.put(result, 'current'); }
          catch (error) { tx.abort(); reject(error); }
        }
      };
      tx.oncomplete = () => { db.close(); resolve(result); };
      tx.onerror = () => { db.close(); reject(new Error('storage_unavailable')); };
      tx.onabort = () => { db.close(); reject(new Error('storage_unavailable')); };
    };
  });
}
function payload(value) {
  if (!value || value.version !== 1 || !uuid.test(value.recipient_user_id) ||
      !uuid.test(value.binding_id) || !uuid.test(value.delivery_id)) return null;
  // Only these identifiers survive. Sender names and message text never render.
  return {version: 1, recipient_user_id: value.recipient_user_id,
    binding_id: value.binding_id, delivery_id: value.delivery_id};
}
function owns(current, data) {
  return current?.active === true && current.user_id === data.recipient_user_id &&
    current.binding_id === data.binding_id;
}
function recent(current) {
  const cutoff = Date.now() - dedupLifetimeMs;
  return (current.deliveries || []).filter(item => Number.isFinite(item.first_seen) && item.first_seen > cutoff);
}
async function shown(data) {
  await record(current => {
    if (!owns(current, data)) return current;
    return {...current, deliveries: recent(current).map(item =>
      item.id === data.delivery_id ? {...item, state: 'shown'} : item)};
  });
}
async function notify(data) {
  // The bridge uses the same lock for unsubscribe and notification cleanup.
  await navigator.locks.request('paul-push-binding', async () => {
    let allowed = false;
    let previous;
    await record(current => {
      if (!owns(current, data)) return current;
      const deliveries = recent(current);
      previous = deliveries.find(item => item.id === data.delivery_id);
      if (!previous && deliveries.length >= dedupCapacity) {
        return {...current, deliveries, storage_full: true};
      }
      allowed = true;
      if (!previous) deliveries.push({id: data.delivery_id, state: 'pending', first_seen: Date.now()});
      return {...current, deliveries, storage_full: false};
    });
    if (!allowed || previous?.state === 'shown') return;
    const tag = `paul-${data.delivery_id}`;
    const visible = await self.registration.getNotifications({tag});
    if (visible.length === 0) {
      // An interrupted pending event can retry. Stable tags recognize a show
      // completed before worker termination. Click/close also confirm it.
      if (!owns(await record(), data)) return;
      await self.registration.showNotification('Paul', {
        body: 'New activity', tag, renotify: false, data,
        icon: new URL('icons/Icon-192.png', self.registration.scope).href,
      });
    }
    await shown(data);
  });
}
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('push', event => {
  event.waitUntil((async () => {
    let data;
    try { data = payload(event.data?.json()); } catch (_) { return; }
    if (data) await notify(data);
  })());
});
self.addEventListener('notificationclose', event => {
  const data = payload(event.notification.data);
  if (data) event.waitUntil(shown(data));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const data = payload(event.notification.data);
    if (!data || !owns(await record(), data)) return;
    await shown(data);
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    const base = new URL(self.registration.scope);
    const target = windows.find(client => {
      const url = new URL(client.url);
      return url.origin === base.origin && url.pathname.startsWith(base.pathname);
    });
    // Recheck after asynchronous client discovery, before delivering the intent.
    if (!owns(await record(), data)) return;
    if (target) {
      target.postMessage({type: 'paul.push.click', ...data});
      await target.focus();
      return;
    }
    const url = new URL(base);
    url.searchParams.set('push_user', data.recipient_user_id);
    url.searchParams.set('push_binding', data.binding_id);
    url.searchParams.set('push_event', data.delivery_id);
    await self.clients.openWindow(url.href);
  })());
});
// Deliberately no fetch/cache handler. Private API responses and photos stay network-only.
