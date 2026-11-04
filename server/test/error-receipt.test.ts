import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';

test('server receipt links a controlled failure to redacted logs and is exposed to allowed web clients', async t => {
  const logs: object[] = [];
  const config = readConfig({ DATABASE_PATH: ':memory:' });
  const { app, store, notifications } = createApp(config, { log: event => logs.push(event), pushTimer: false });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  t.after(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await notifications.stop();
    store.close();
  });
  const original = store.one;
  store.one = () => { throw new Error('password=private-example token=private-token mobile=13800138000'); };
  const response = await fetch(`http://127.0.0.1:${address.port}/ready`, {
    headers: { Origin: config.publicBaseUrl, 'X-Request-Id': 'untrusted-input' },
  });
  store.one = original;
  const id = response.headers.get('x-request-id');
  assert.equal(response.status, 500);
  assert.match(id!, /^[a-f\d]{8}-[a-f\d]{4}-4[a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/);
  assert.match(response.headers.get('access-control-expose-headers')!, /X-Request-Id/i);
  assert(logs.some((event: any) => event.requestId === id && event.event === 'internal_error'));
  assert(logs.some((event: any) => event.requestId === id && event.status === 500));
  const output = JSON.stringify(logs) + JSON.stringify(await response.json());
  for (const secret of ['private-example', 'private-token', '13800138000', 'untrusted-input']) {
    assert(!output.includes(secret));
  }
});
