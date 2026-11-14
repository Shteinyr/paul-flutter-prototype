import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../web/paul_public_preview_bootstrap.js', import.meta.url), 'utf8');
const endpoint = 'https://public.invalid/functions/v1/public-preview';
const page = {profiles: [], query: '', next_cursor: null};
function boot({settings = {url: 'https://public.invalid', key: 'publishable'}, href = 'https://app.invalid/', reply} = {}) {
  let now = 1000;
  const requests = [];
  const timers = new Map();
  const context = {
    URL, AbortController, location: {href}, Date: {now: () => now},
    setTimeout(fn) { const id = timers.size + 1; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); },
    fetch(url, options) {
      requests.push({url, options});
      return reply ? reply(url, options) : Promise.resolve({ok: true, text: async () => JSON.stringify(page)});
    },
  };
  vm.createContext(context);
  vm.runInContext(source.replace('/* PAUL_PUBLIC_PREVIEW_SETTINGS */ null', JSON.stringify(settings)), context);
  return {context, requests, timers, advance(ms) { now += ms; }};
}

test('public profiles start before Flutter and are consumed exactly once without Auth or cookies', async () => {
  let answer;
  const state = boot({reply: () => new Promise(resolve => {answer = resolve;})});
  assert.equal(state.requests.length, 1, 'HTTP already started before the Flutter caller exists');
  const {options} = state.requests[0];
  assert.deepEqual(JSON.parse(options.body), {action: 'profiles', query: '', kind: 'all'});
  assert.equal(options.credentials, 'omit');
  assert.equal(options.referrerPolicy, 'no-referrer');
  assert.equal(Object.keys(options.headers).some(k => /authorization|cookie/i.test(k)), false);
  assert.deepEqual(Object.keys(options.headers), ['Content-Type']);
  assert.equal(options.headers['Content-Type'], 'text/plain;charset=UTF-8');
  state.advance(6000); // Engine initialization overlaps the pending HTTP call.
  answer({ok: true, text: async () => JSON.stringify(page)});
  assert.deepEqual(JSON.parse(await state.context.paulPublicPreviewBootstrap.take(endpoint, 'publishable')), page);
  assert.equal(await state.context.paulPublicPreviewBootstrap.take(endpoint, 'publishable'), 'null');
  assert.equal(state.timers.size, 0);
});

test('a response cannot cross endpoint/key boundaries and expires after a slow engine load', async () => {
  const state = boot();
  const bridge = state.context.paulPublicPreviewBootstrap;
  assert.equal(await bridge.take('https://other.invalid/', 'publishable'), 'null');
  assert.equal(await bridge.take(endpoint, 'other-key'), 'null');
  await new Promise(resolve => setImmediate(resolve));
  state.advance(15001);
  assert.equal(await bridge.take(endpoint, 'publishable'), 'null');
});

test('errors and oversized/malformed responses expose one failed attempt without unhandled rejection', async () => {
  for (const reply of [
    async () => {throw new Error('offline');},
    async () => ({ok: false}),
    async () => ({ok: true, text: async () => '{'}),
    async () => ({ok: true, text: async () => 'x'.repeat(1048577)}),
    async () => ({ok: true, text: async () => JSON.stringify({profiles: [], query: 'wrong'})}),
  ]) {
    const state = boot({reply});
    assert.deepEqual(JSON.parse(await state.context.paulPublicPreviewBootstrap.take(endpoint, 'publishable')), {__paul_bootstrap_failed: true});
    assert.equal(state.timers.size, 0);
  }
});

test('timeout aborts the public request and leaves the normal client free to retry', async () => {
  const state = boot({reply: (_, options) => new Promise((_, reject) => {
    options.signal.addEventListener('abort', () => reject(new Error('aborted')));
  })});
  [...state.timers.values()][0]();
  assert.deepEqual(JSON.parse(await state.context.paulPublicPreviewBootstrap.take(endpoint, 'publishable')), {__paul_bootstrap_failed: true});
  assert.equal(state.requests[0].options.signal.aborted, true);
});

test('demo/missing settings and OAuth callback do not start speculative requests', () => {
  for (const options of [{settings: null}, {settings: {url: '', key: ''}},
    {href: 'https://app.invalid/?auth=callback&code=local-only'}]) {
    const state = boot(options);
    assert.equal(state.requests.length, 0);
    assert.equal(state.context.paulPublicPreviewBootstrap, undefined);
  }
});
