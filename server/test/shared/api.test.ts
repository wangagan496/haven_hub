import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, type Envelope } from '../helpers/api-fixture.js';

test('visitor, profile, announcement and upload contracts are usable by the app', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const b = await f.login('13800138001');
  const { record: house } = await f.room(a.token);
  const visitor = await f.request('POST', '/visitor', a.token, { houseId: house.id, name: '李四', gender: 0,
    mobile: '13800138001', visitDate: '2026-10-20' });
  assert.equal(visitor.code, 10000);
  assert.equal(visitor.data.total, 1);
  assert.equal(visitor.data.rows[0].status, 1);
  assert.equal((await f.request('GET', `/visitor/${visitor.data.rows[0].id}`, b.token)).status, 404);
  const png = await fetch(f.base + new URL(visitor.data.rows[0].url).pathname, { headers: { Authorization: `Bearer ${a.token}` } });
  assert.equal(png.headers.get('content-type'), 'image/png');
  assert.deepEqual([...new Uint8Array(await png.arrayBuffer()).slice(0, 4)], [137, 80, 78, 71]);
  const profile = await f.request('PUT', '/userInfo', a.token, { nickName: '测试用户', avatar: await f.upload(a.token) });
  assert.equal(profile.data.nickName, '测试用户');
  assert(profile.data.id);
  assert.equal((await f.request('GET', '/announcement')).data.length, 1);
  assert.equal((await f.request('GET', '/announcement/local-welcome')).code, 10000);
  assert.equal((await f.request('GET', '/repairItem', a.token)).data.length, 4);
});

test('rejects unauthenticated writes, malformed uploads, invalid JSON and disallowed browser origins', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('POST', '/room', undefined, {})).status, 401);
  assert.equal((await f.request('GET', '/code?mobile=invalid')).code, 40000);
  const a = await f.login();
  const form = new FormData();
  form.append('file', new Blob(['not an image']), 'fake.png');
  const upload = await fetch(f.base + '/upload', { method: 'POST', headers: { Authorization: `Bearer ${a.token}` }, body: form });
  assert.notEqual((await upload.json() as Envelope).code, 10000);
  const json = await fetch(f.base + '/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(json.status, 400);
  const forbidden = await fetch(f.base + '/health', { headers: { Origin: 'https://untrusted.example' } });
  assert.equal(forbidden.status, 403);
  const allowed = await fetch(f.base + '/health', { headers: { Origin: 'http://localhost:8080' } });
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'http://localhost:8080');
  const preflight = await fetch(f.base + '/repair', { method: 'OPTIONS', headers: { Origin: 'http://localhost:8080', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'authorization,content-type' } });
  assert.equal(preflight.status, 204);
});
