/** Real Chromium SW/IDB/locks regression. CDP push is injection, not remote delivery. */
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdtemp, mkdir, rm} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {createECDH} from 'node:crypto';
const require = createRequire(import.meta.url);
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright-core');
const root = new URL('../web/', import.meta.url);
const server = createServer(async (request, response) => {
  const name = new URL(request.url, 'http://localhost').pathname.slice(1);
  if (name === '' || name === 'test.html') {
    response.setHeader('Content-Type', 'text/html');
    response.end('<!doctype html><html><body><script src="paul_push.js"></script></body></html>');
  } else if (['paul_push.js', 'paul_push_worker.js'].includes(name)) {
    response.setHeader('Content-Type', 'application/javascript');
    response.setHeader('Cache-Control', 'no-store');
    response.end(await readFile(new URL(name, root)));
  } else { response.statusCode = 404; response.end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const user = '10000000-0000-4000-8000-000000000001';
const session = '10000000-0000-4000-8000-000000000002';
const bound = '10000000-0000-4000-8000-000000000003';
const delivery = '10000000-0000-4000-8000-000000000004';
const other = '10000000-0000-4000-8000-000000000005';
const otherSession = '10000000-0000-4000-8000-000000000006';
let browser;
let profile;
let context;
try {
  const launch = {headless: process.env.PUSH_HEADED !== '1', ignoreDefaultArgs: ['--disable-background-networking'], executablePath: process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'};
  if (process.env.PUSH_REAL_SUBSCRIBE === '1') {
    await mkdir(new URL('../build/', import.meta.url), {recursive: true});
    profile = await mkdtemp(fileURLToPath(new URL('../build/push-profile-', import.meta.url)));
    context = await chromium.launchPersistentContext(profile, {...launch, permissions: ['notifications']});
    browser = context.browser();
  } else {
    browser = await chromium.launch(launch);
    context = await browser.newContext({permissions: ['notifications']});
  }
  const errors = [];
  context.on('page', page => page.on('pageerror', error => errors.push(error.message)));
  const page = await context.newPage();
  const cdp = await context.newCDPSession(page);
  let registrationId;
  cdp.on('ServiceWorker.workerRegistrationUpdated', ({registrations}) => {
    const own = registrations.find(item => item.scopeURL === `${origin}/` && !item.isDeleted);
    if (own) registrationId = own.registrationId;
  });
  await cdp.send('ServiceWorker.enable');
  await page.goto(`${origin}/test.html`);
  await page.evaluate(async () => {
    const reg = await navigator.serviceWorker.register('paul_push_worker.js');
    await navigator.serviceWorker.ready;
    if (!reg.active) await new Promise(resolve => navigator.serviceWorker.addEventListener('controllerchange', resolve, {once: true}));
  });
  await page.waitForFunction(() => navigator.serviceWorker.controller);
  async function readRecord(target = page) {
    return target.evaluate(() => new Promise((resolve, reject) => {
      const request = indexedDB.open('paul-push-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('binding');
      request.onerror = () => reject(new Error('IDB test failure'));
      request.onsuccess = () => {
        const db = request.result, tx = db.transaction('binding');
        const read = tx.objectStore('binding').get('current');
        tx.oncomplete = () => {db.close(); resolve(read.result);};
      };
    }));
  }
  async function seed(value) {
    await page.evaluate(value => new Promise(resolve => {
      const request = indexedDB.open('paul-push-v1', 1);
      request.onupgradeneeded = () => request.result.createObjectStore('binding');
      request.onsuccess = () => {
        const db = request.result, tx = db.transaction('binding', 'readwrite');
        tx.objectStore('binding').put(value, 'current');
        tx.oncomplete = () => {db.close(); resolve();};
      };
    }), value);
  }
  async function notifications() {
    return page.evaluate(async () => (await (await navigator.serviceWorker.ready).getNotifications()).map(item => ({title: item.title, body: item.body, data: item.data})));
  }
  async function waitFor(predicate, label) {
    for (let n = 0; n < 150; n++) {
      if (await predicate()) return;
      await new Promise(resolve => setTimeout(resolve, 40));
    }
    throw new Error(`Timed out: ${label}`);
  }
  async function inject(id = delivery, recipient = user, bindingId = bound, kind = 'message_created') {
    assert.ok(registrationId);
    await cdp.send('ServiceWorker.deliverPushMessage', {origin, registrationId,
      data: JSON.stringify({version: 1, delivery_id: id, recipient_user_id: recipient, binding_id: bindingId, kind,
        title: 'Private sender must never display', body: 'Private message must never display'})});
  }
  await page.evaluate(([user, session]) => paulPush.identity(user, session), [user, session]);
  await seed({user_id: user, session_id: session, binding_id: bound, active: true, revision: 'fixture'});
  await inject();
  await waitFor(async () => (await readRecord())?.deliveries?.some(item => item.id === delivery && item.state === 'shown'), 'actual SW notification');
  const displayed = await notifications();
  assert.equal(displayed.length, 1);
  assert.equal(displayed[0].title, 'Paul');
  assert.equal(displayed[0].body, 'New message');
  assert.deepEqual(Object.keys(displayed[0].data).sort(), ['version', 'delivery_id', 'recipient_user_id', 'binding_id', 'kind'].sort());
  const hiringId = '40000000-0000-4000-8000-000000000002';
  await inject(hiringId, user, bound, 'community_created');
  await waitFor(async () => (await notifications()).length === 2, 'separate Hiring notification');
  assert.equal((await notifications()).find(item => item.data.delivery_id === hiringId).body, 'New Hiring request');
  await inject('40000000-0000-4000-8000-000000000003', user, bound, 'Private event');
  await new Promise(resolve => setTimeout(resolve, 100));
  assert.equal((await notifications()).length, 2);
  await page.evaluate(async () => { for (const item of await (await navigator.serviceWorker.ready).getNotifications()) item.close(); });
  await cdp.send('ServiceWorker.stopAllWorkers');
  await inject();
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.equal((await notifications()).length, 0);
  console.log(JSON.stringify({gate: 'real SW durable dedup after close and worker restart', passed: true, remoteDelivery: false}));

  const pendingId = '40000000-0000-4000-8000-000000000001';
  const beforePending = await readRecord();
  await seed({...beforePending, deliveries: [...beforePending.deliveries,
    {id: pendingId, state: 'pending', first_seen: Date.now()}]});
  await cdp.send('ServiceWorker.stopAllWorkers');
  await inject(pendingId);
  await waitFor(async () => (await readRecord()).deliveries.some(item => item.id === pendingId && item.state === 'shown'), 'interrupted pending recovery');
  assert.equal((await notifications()).length, 1);
  await page.evaluate(async () => { for (const item of await (await navigator.serviceWorker.ready).getNotifications()) item.close(); });
  console.log(JSON.stringify({gate: 'durable pending recovers after worker termination', passed: true, remoteDelivery: false}));

  // Bulk delivery exercises real SW/IDB; stub presentation to avoid 129 OS banners.
  let bulkWorker = context.serviceWorkers().find(worker => worker.url().endsWith('paul_push_worker.js'));
  await bulkWorker.evaluate(() => {
    self.pushOriginalShow = self.registration.showNotification.bind(self.registration);
    self.registration.showNotification = async () => {};
  });
  const beforeBulkCount = (await readRecord()).deliveries.length;
  for (let n = 10; n < 139; n++) await inject(`20000000-0000-4000-8000-${String(n).padStart(12, '0')}`);
  await waitFor(async () => (await readRecord()).deliveries.length === beforeBulkCount + 129, '129 newer delivery records');
  await bulkWorker.evaluate(() => { self.registration.showNotification = self.pushOriginalShow; });
  await inject();
  await new Promise(resolve => setTimeout(resolve, 300));
  assert.equal((await notifications()).length, 0);
  assert.ok((await readRecord()).deliveries.some(item => item.id === delivery));
  console.log(JSON.stringify({gate: 'show close 129 newer events then old retry', passed: true, bulkPresentationStub: true}));
  const young = Date.now();
  const many = Array.from({length: 8191}, (_, n) => ({id: `30000000-0000-4000-8000-${String(n).padStart(12, '0')}`, state: 'shown', first_seen: young}));
  await seed({...await readRecord(), deliveries: [{id: delivery, state: 'shown', first_seen: young}, ...many]});
  await inject(otherSession);
  await waitFor(async () => (await readRecord()).storage_full === true, 'capacity fail-closed');
  assert.equal((await notifications()).length, 0);
  await inject();
  await new Promise(resolve => setTimeout(resolve, 200));
  assert.equal((await notifications()).length, 0);
  const aged = many.map(item => ({...item, first_seen: young - 27 * 60 * 60 * 1000}));
  await seed({...await readRecord(), deliveries: [{id: delivery, state: 'shown', first_seen: young}, ...aged]});
  await inject(otherSession);
  await waitFor(async () => (await readRecord()).deliveries.length === 2 && (await notifications()).length === 1, 'safe age pruning');
  await page.evaluate(async () => { for (const item of await (await navigator.serviceWorker.ready).getNotifications()) item.close(); });
  console.log(JSON.stringify({gate: '26h age pruning and 8192 capacity retains young dedup', passed: true}));

  // Pause a real notification call while logout publishes its tombstone.
  await inject(other);
  await waitFor(async () => (await notifications()).length === 1, 'worker resumed');
  const worker = context.serviceWorkers().find(worker => worker.url().endsWith('paul_push_worker.js'));
  assert.ok(worker);
  await worker.evaluate(() => {
    const original = self.registration.showNotification.bind(self.registration);
    self.registration.showNotification = async (...args) => {
      self.pushTestWaiting = true;
      await new Promise(resolve => { self.pushTestContinue = resolve; });
      return original(...args);
    };
  });
  await inject('10000000-0000-4000-8000-000000000007');
  await waitFor(() => worker.evaluate(() => self.pushTestWaiting === true), 'paused show');
  const clearing = page.evaluate(([user, session]) => paulPush.clear(user, session), [user, session]);
  await waitFor(async () => (await readRecord())?.user_id === null, 'logout tombstone');
  await worker.evaluate(() => self.pushTestContinue());
  await clearing;
  assert.equal((await notifications()).length, 0);
  await inject(bound);
  await new Promise(resolve => setTimeout(resolve, 300));
  assert.equal((await notifications()).length, 0);
  console.log(JSON.stringify({gate: 'real SW late show versus logout and queued push', passed: true, remoteDelivery: false}));

  if (process.env.PUSH_REAL_SUBSCRIBE === '1') {
    const nativeKey = createECDH('prime256v1'); nativeKey.generateKeys();
    let timedOut = false;
    try {
      await page.evaluate(([user, session]) => paulPush.identity(user, session), [user, session]);
      const started = Date.now();
      const probe = page.evaluate(([user, key]) => paulPush.prepare(user, key), [user, nativeKey.getPublicKey().toString('base64url')]);
      const timeout = Number(process.env.PUSH_NATIVE_TIMEOUT_MS || '30000');
      let timer;
      const result = await Promise.race([probe.then(() => ({subscribed: true})).catch(error => ({subscribed: false, message: error.message.slice(0, 180)})),
        new Promise(resolve => { timer = setTimeout(() => resolve({subscribed: false, message: 'Native subscription exceeded timeout'}), timeout); })]);
      clearTimeout(timer);
      timedOut = result.message === 'Native subscription exceeded timeout';
      console.log(JSON.stringify({gate: 'native PushManager subscription probe', ...result, elapsedMs: Date.now() - started, persistentProfile: true, headed: process.env.PUSH_HEADED === '1', backgroundNetworkingEnabled: true, permission: await page.evaluate(() => Notification.permission), remoteDelivery: false}));
      if (timedOut) throw new Error('Native subscription probe timed out');
    } finally {
      if (timedOut) await context.close();
      else await page.evaluate(([user, session]) => paulPush.clear(user, session), [user, session]);
    }
  }

  // These races use real IDB/Web Locks with a synthetic PushManager capability.
  async function fakeManager(target) {
    await target.evaluate(() => {
      async function storage(change) {
        return new Promise(resolve => {
          const request = indexedDB.open('paul-push-v1', 1);
          request.onsuccess = () => {
            const db = request.result, tx = db.transaction('binding', change ? 'readwrite' : 'readonly');
            const store = tx.objectStore('binding'), read = store.get('syntheticEndpoint');
            let value;
            read.onsuccess = () => { value = read.result; if (change) { value = change(value); store.put(value, 'syntheticEndpoint'); } };
            tx.oncomplete = () => {db.close(); resolve(value);};
          };
        });
      }
      const wrap = id => id ? {toJSON: () => ({endpoint: id, expirationTime: null, keys: {p256dh: 'synthetic', auth: 'synthetic'}}),
        unsubscribe: async () => {await storage(current => current === id ? null : current); return true;}} : null;
      PushManager.prototype.getSubscription = async () => wrap(await storage());
      PushManager.prototype.subscribe = async () => wrap(await storage(() => crypto.randomUUID()));
    });
  }
  await fakeManager(page);
  const second = await context.newPage();
  await second.goto(`${origin}/test.html`);
  await fakeManager(second);
  const ecdh = createECDH('prime256v1'); ecdh.generateKeys();
  const publicKey = ecdh.getPublicKey().toString('base64url');
  await page.evaluate(([user, session]) => paulPush.identity(user, session), [user, session]);
  const firstPending = JSON.parse(await page.evaluate(([user, key]) => paulPush.prepare(user, key), [user, publicKey]));
  await second.evaluate(([user, session]) => paulPush.identity(user, session), [other, otherSession]);
  const secondPending = JSON.parse(await second.evaluate(([user, key]) => paulPush.prepare(user, key), [other, publicKey]));
  await second.evaluate(([user, binding]) => paulPush.commit(user, binding, binding), [other, secondPending.binding_id]);
  await assert.rejects(page.evaluate(([user, binding]) => paulPush.commit(user, binding, binding), [user, firstPending.binding_id]));
  await page.evaluate(([user, session]) => paulPush.clear(user, session), [user, session]);
  const safe = await readRecord();
  assert.equal(safe.user_id, other);
  assert.equal(safe.binding_id, secondPending.binding_id);
  assert.equal(safe.active, true);
  console.log(JSON.stringify({gate: 'real IDB/Web Locks multi-tab late ACK and old-account clear', passed: true, syntheticSubscription: true}));

  await page.evaluate(([user, session]) => paulPush.identity(user, session), [other, session]);
  const fresh = JSON.parse(await page.evaluate(([user, key]) => paulPush.prepare(user, key), [other, publicKey]));
  await page.evaluate(([user, id]) => paulPush.commit(user, id, id), [other, fresh.binding_id]);
  await second.evaluate(([user, session]) => paulPush.clear(user, session), [other, otherSession]);
  assert.equal((await readRecord()).binding_id, fresh.binding_id);
  assert.equal((await readRecord()).active, true);
  console.log(JSON.stringify({gate: 'same-user new session survives stale session cleanup', passed: true, syntheticSubscription: true}));
  await page.evaluate(async () => { await (await navigator.serviceWorker.ready).pushManager.subscribe(); });
  const rotated = JSON.parse(await page.evaluate(() => paulPush.inspect()));
  assert.equal(rotated.binding?.active === true, false, 'Rotated endpoint cannot retain the old active server binding');
  console.log(JSON.stringify({gate: 'rotated native endpoint cannot appear as active old binding', passed: true, syntheticSubscription: true}));
  const beforeRebind = await readRecord();
  const rebound = JSON.parse(await page.evaluate(([user, key]) => paulPush.prepare(user, key), [other, publicKey]));
  assert.notEqual(rebound.binding_id, beforeRebind.binding_id);
  const retry = JSON.parse(await page.evaluate(([user, key]) => paulPush.prepare(user, key), [other, publicKey]));
  assert.equal(retry.binding_id, rebound.binding_id, 'Lost ACK retry retains the pending generation');
  await page.evaluate(([user, id]) => paulPush.commit(user, id, id), [other, rebound.binding_id]);
  await seed({...await readRecord(), subscription_hash: undefined});
  const legacy = JSON.parse(await page.evaluate(() => paulPush.inspect()));
  assert.equal(legacy.binding.active, false);
  const migrated = JSON.parse(await page.evaluate(([user, key]) => paulPush.prepare(user, key), [other, publicKey]));
  assert.notEqual(migrated.binding_id, rebound.binding_id);
  console.log(JSON.stringify({gate: 'legacy fingerprint and lost ACK rebind recovery', passed: true, syntheticSubscription: true}));
  assert.deepEqual(errors, []);
  await context.close();
  console.log(JSON.stringify({gate: 'push browser regression', passed: true, pageErrors: 0, contextsClosed: true}));
} finally {
  if (context) await context.close();
  if (browser) await browser.close();
  if (profile) await rm(profile, {recursive: true, force: true});
  await new Promise(resolve => server.close(resolve));
}
