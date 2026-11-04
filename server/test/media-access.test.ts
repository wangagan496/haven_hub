import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/database.js';
import { readMedia, requireMediaPurpose } from '../src/media.js';
import { fixture, SLOT } from './repair-fixture.js';

test('version-eight migration backfills mixed-purpose images and preserves identity restrictions after deletion and reopening', t => {
  const dir = mkdtempSync(join(tmpdir(), 'haven-media-migration-'));
  const path = join(dir, 'database.sqlite');
  let store = new Store(path);
  t.after(() => { store.close(); rmSync(dir, { recursive: true }); });
  for (const [id, mobile, role] of [['owner', '13800138000', 'resident'], ['worker', '13800138001', 'worker'], ['admin', '13800138002', 'admin']] as const) {
    store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', id, mobile, id, role);
  }
  const id = 'b'.repeat(64), url = `http://127.0.0.1/media/${id}`;
  store.run('INSERT INTO uploads VALUES (?,?,?,?)', id, 'owner', 'image/png', Buffer.from('legacy-identity'));
  store.save('rooms', 'owner', { id: 'house', idcardFrontUrl: url });
  store.save('repairs', 'owner', { id: 'repair', attachment: [url], workerId: 'worker' });
  store.db.exec('DROP TABLE upload_bindings; DROP TABLE account_events; ALTER TABLE users DROP COLUMN disabledAt; PRAGMA user_version=8');
  store.close();
  store = new Store(path);
  assert.equal(store.one('SELECT COUNT(*) AS n FROM upload_bindings')!.n, 2);
  assert.equal(readMedia(store, 'admin', id).mime, 'image/png');
  assert.throws(() => readMedia(store, 'worker', id), /无权访问/);
  store.delete('rooms', 'owner', 'house');
  store.close();
  store = new Store(path);
  assert.throws(() => readMedia(store, 'worker', id), /无权访问/);
  assert.throws(() => readMedia(store, 'admin', id), /无权访问/);
  assert.throws(() => requireMediaPurpose(store, id, 'repair'), /其他用途/);
  assert.equal(Buffer.from(readMedia(store, 'owner', id).bytes as Uint8Array).toString(), 'legacy-identity');
});

test('unbound media requires login and belongs only to its uploader', async t => {
  const f = await fixture(t);
  const id = randomBytes(32).toString('hex');
  f.store.run('INSERT INTO uploads(id,userId,mime,bytes) VALUES (?,?,?,?)', id, f.ids.resident, 'image/png', Buffer.from('private-photo'));
  const read = (token = '') => fetch(`${f.base}/media/${id}`, { headers: token ? { Authorization: `Bearer ${token}` } : {} });
  assert.equal((await read()).status, 401);
  for (const role of ['other', 'admin', 'worker'] as const) assert.equal((await read(f.tokens[role])).status, 404);
  const own = await read(f.tokens.resident);
  assert.equal(own.status, 200);
  assert.equal(await own.text(), 'private-photo');
  assert.match(own.headers.get('cache-control')!, /no-store/);
  assert.equal((await fetch(`${f.base}/media/${'e'.repeat(64)}`, { headers: { Authorization: `Bearer ${f.tokens.other}` } })).status, 404);
});

test('repair photos follow current assignment and never grant access to the repair pool', async t => {
  const f = await fixture(t);
  const id = randomBytes(32).toString('hex');
  const url = `${f.config.publicBaseUrl}/media/${id}`;
  f.store.run('INSERT INTO uploads(id,userId,mime,bytes) VALUES (?,?,?,?)', id, f.ids.resident, 'image/png', Buffer.from('repair-photo'));
  let row = await f.create(SLOT, { attachment: [url] });
  const read = async (role: 'resident' | 'other' | 'worker' | 'worker2' | 'admin') =>
    (await fetch(`${f.base}/media/${id}`, { headers: { Authorization: `Bearer ${f.tokens[role]}` } })).status;
  assert.equal(await read('admin'), 200);
  assert.equal(await read('worker'), 404);
  assert.equal(await read('other'), 404);
  row = await f.change('admin', row, 'assign', { workerId: f.ids.worker });
  assert.equal(await read('worker'), 200);
  assert.equal(await read('worker2'), 404);
  await f.change('admin', row, 'assign', { workerId: f.ids.worker2 });
  assert.equal(await read('worker'), 404);
  assert.equal(await read('worker2'), 200);
  f.store.run("UPDATE users SET role='resident' WHERE id=?", f.ids.worker2);
  assert.equal(await read('worker2'), 404);
});

test('identity images remain restricted, cannot be reused as repair photos or avatars, and lose reviewer access after removal', async t => {
  const f = await fixture(t);
  const id = randomBytes(32).toString('hex');
  const url = `${f.config.publicBaseUrl}/media/${id}`;
  f.store.run('INSERT INTO uploads(id,userId,mime,bytes) VALUES (?,?,?,?)', id, f.ids.resident, 'image/png', Buffer.from('identity-photo'));
  const house = f.store.get('rooms', f.ids.resident, f.body.houseId)!;
  f.store.save('rooms', f.ids.resident, { ...house, idcardFrontUrl: url, idcardBackUrl: url }, true);
  const read = async (role: 'admin' | 'resident' | 'worker') => (await fetch(`${f.base}/media/${id}`, {
    headers: { Authorization: `Bearer ${f.tokens[role]}` },
  })).status;
  assert.equal(await read('admin'), 200);
  assert.equal(await read('worker'), 404);
  assert.notEqual((await f.raw('resident', 'POST', '/repair', { ...f.body, slot: SLOT, attachment: [url] })).code, 10000);
  assert.notEqual((await f.raw('resident', 'PUT', '/userInfo', { nickName: '测试用户', avatar: url })).code, 10000);
  // Historical mixed-purpose data is fail-closed even if the worker owns the related repair assignment.
  const row = await f.create();
  f.store.save('repairs', f.ids.resident, { ...row, id: row.id, attachment: [url], workerId: f.ids.worker }, true);
  assert.equal(await read('worker'), 404);
  f.store.delete('rooms', f.ids.resident, house.id);
  assert.equal(await read('admin'), 404);
  assert.equal(await read('resident'), 200);
});
