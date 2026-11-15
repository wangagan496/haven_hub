import test from 'node:test';
import assert from 'node:assert/strict';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';

for (const trust of ['0', '1']) {
  test(`auth limiter ${trust === '1' ? 'separates forwarded real IPs with a configured proxy' : 'ignores spoofed forwarding without proxy trust'}`, async t => {
    const { app, store } = createApp(readConfig({ DATABASE_PATH: ':memory:', TRUST_PROXY: trust }), { log: () => {}, pushTimer: false });
    const server = app.listen(0, '127.0.0.1');
    await new Promise<void>(resolve => server.once('listening', resolve));
    t.after(async () => { await new Promise<void>(resolve => server.close(() => resolve())); store.close(); });
    const address = server.address(); assert(address && typeof address !== 'string');
    const send = (ip: string) => fetch(`http://127.0.0.1:${address.port}/login`, {
      method: 'POST', headers: { 'X-Forwarded-For': ip, 'Content-Type': 'application/json' }, body: '{}',
    });
    for (let i = 0; i < 30; i++) assert.notEqual((await send('198.51.100.1')).status, 429);
    assert.equal((await send('198.51.100.1')).status, 429);
    const other = await send('203.0.113.1');
    if (trust === '1') assert.notEqual(other.status, 429);
    else assert.equal(other.status, 429);
  });
}
