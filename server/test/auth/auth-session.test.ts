import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from '../helpers/api-fixture.js';

test('login codes are single use, expire, enforce cooldown and attempt limit; sessions rotate', async t => {
  let now = Date.now();
  const f = await fixture(t, ':memory:', () => now);
  const first = await f.request('GET', '/code?mobile=13800138000');
  assert.equal((await f.request('GET', '/code?mobile=13800138000')).status, 429);
  const credentials = { mobile: '13800138000', code: first.data.code };
  const session = (await f.request('POST', '/login', undefined, credentials)).data;
  assert.notEqual((await f.request('POST', '/login', undefined, credentials)).code, 10000);
  assert.equal((await f.request('GET', '/userInfo', session.token)).code, 10000);
  now += 31 * 60_000;
  assert.equal((await f.request('GET', '/userInfo', session.token)).status, 401);
  const rotated = await f.request('POST', '/refreshToken', session.refreshToken);
  assert.equal(rotated.code, 10000);
  assert.equal((await f.request('GET', '/userInfo', rotated.data.token)).code, 10000);
  assert.equal((await f.request('POST', '/refreshToken', session.refreshToken)).status, 401);
  const expired = await f.request('GET', '/code?mobile=13800138001');
  now += 301_000;
  assert.notEqual((await f.request('POST', '/login', undefined, { mobile: '13800138001', code: expired.data.code })).code, 10000);
  const attempts = await f.request('GET', '/code?mobile=13800138002');
  for (let i = 0; i < 5; i++) await f.request('POST', '/login', undefined,
    { mobile: '13800138002', code: attempts.data.code === '000000' ? '111111' : '000000' });
  assert.notEqual((await f.request('POST', '/login', undefined, { mobile: '13800138002', code: attempts.data.code })).code, 10000);
  assert(!JSON.stringify(f.logs).includes(session.token));
  assert(!JSON.stringify(f.logs).includes('13800138000'));
});
