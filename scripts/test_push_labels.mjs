/** Notification event contract tests. No provider delivery or OS screenshots. */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(new URL('../web/paul_push_worker.js', import.meta.url), 'utf8');
const user = '10000000-0000-4000-8000-000000000001';
const binding = '10000000-0000-4000-8000-000000000002';
const message = '10000000-0000-4000-8000-000000000003';
const hiring = '10000000-0000-4000-8000-000000000004';

function harness() {
  const handlers = {}, visible = [];
  let current = {user_id: user, binding_id: binding, active: true, deliveries: []};
  const context = vm.createContext({
    URL, Date,
    navigator: {locks: {request: async (_, action) => action()}},
    self: {
      addEventListener: (name, action) => {handlers[name] = action;},
      registration: {
        scope: 'https://paul.example.test/',
        getNotifications: async ({tag}) => visible.filter(item => item.tag === tag),
        showNotification: async (title, options) => {visible.push({title, ...options});},
      },
    },
    testRecord: async change => {
      if (change) current = change(current);
      return current;
    },
  });
  vm.runInContext(source + '\nrecord = testRecord;', context);
  return {
    visible,
    push: async value => {
      let work;
      handlers.push({data: {json: () => value}, waitUntil: value => {work = value;}});
      await work;
    },
  };
}
function event(id, kind) {
  return {version: 1, recipient_user_id: user, binding_id: binding, delivery_id: id,
    ...(kind === undefined ? {} : {kind}),
    title: 'Private sender', body: 'Private message', skill: 'Private skill'};
}

test('message and Hiring show distinct fixed labels with no personal content', async () => {
  const check = harness();
  await check.push(event(message, 'message_created'));
  await check.push(event(hiring, 'community_created'));
  assert.deepEqual(check.visible.map(item => [item.title, item.body]),
    [['Paul', 'New message'], ['Paul', 'New Hiring request']]);
  assert.notEqual(check.visible[0].tag, check.visible[1].tag);
  for (const item of check.visible) {
    assert.deepEqual(Object.keys(item.data).sort(),
      ['version', 'recipient_user_id', 'binding_id', 'delivery_id', 'kind'].sort());
    assert.equal(JSON.stringify(item).includes('Private'), false);
  }
});

test('typed delivery retries retain one notification for each delivery', async () => {
  const check = harness();
  await check.push(event(message, 'message_created'));
  await check.push(event(message, 'message_created'));
  await check.push(event(hiring, 'community_created'));
  assert.equal(check.visible.length, 2);
});

test('unknown types and another account never display a notification', async () => {
  const check = harness();
  await check.push(event(message, 'Private custom event'));
  await check.push({...event(hiring, 'community_created'), recipient_user_id: message});
  assert.equal(check.visible.length, 0);
});

test('an in-flight legacy payload still opens with its original neutral label', async () => {
  const check = harness();
  await check.push(event(message));
  assert.equal(check.visible[0].body, 'New activity');
  assert.equal('kind' in check.visible[0].data, false);
});
