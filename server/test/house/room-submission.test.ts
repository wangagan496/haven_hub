import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { HousingService } from '../../src/housing/service.js';
import { fixture } from '../helpers/api-fixture.js';

test('room submission: concurrent retries return one house and preserve English-name uniqueness', async t => {
  const f = await fixture(t);
  const user = await f.login();
  const { body } = await f.room(user.token);
  const input = { ...body, name: 'John Smith', submissionId: randomUUID() };
  const replies = await Promise.all(Array.from({ length: 4 }, () => f.request('POST', '/room', user.token, input)));
  const first = replies[0];
  assert.ok(first);
  assert.equal(first.code, 10000);
  assert.ok(first.data.createdId);
  for (const reply of replies) {
    assert.equal(reply.code, 10000);
    assert.equal(reply.data.createdId, first.data.createdId);
    assert.equal(reply.data.rows.length, 2);
  }
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM room_submissions')!.n), 1);
  assert.equal((await f.request('POST', '/room', user.token, { ...input, submissionId: randomUUID() })).code, 40002);
});

test('room submission: changed content conflicts while replay returns later edits without overwriting them', async t => {
  const f = await fixture(t);
  const user = await f.login();
  const { body } = await f.room(user.token);
  const input = { ...body, submissionId: randomUUID() };
  const created = await f.request('POST', '/room', user.token, input);
  assert.equal(created.code, 10000);
  for (const change of [{ room: '999' }, { name: '李四' }, { mobile: '13800138001' }, { gender: 0 }]) {
    const conflict = await f.request('POST', '/room', user.token, { ...input, ...change });
    assert.equal(conflict.status, 409);
    assert.equal(conflict.code, 40902);
  }
  const id = created.data.createdId;
  assert.equal((await f.request('POST', '/room', user.token, { ...body, id, revision: 1, room: '103' })).code, 10000);
  const replay = await f.request('POST', '/room', user.token, { ...input, name: ` ${input.name} `, floor: '' });
  assert.equal(replay.code, 10000);
  assert.equal(replay.data.createdId, id);
  const current = replay.data.rows.find((row: { id: string }) => row.id === id);
  assert.equal(current.room, '103');
  assert.equal(current.revision, 2);
  const mixedEdit = await f.request('POST', '/room', user.token, { ...input, id, revision: 2 });
  assert.equal(mixedEdit.code, 40000);
});

test('room submission: authenticated account scope and photo ownership cannot be bypassed', async t => {
  const f = await fixture(t);
  const a = await f.login();
  const b = await f.login('13800138001');
  const { body: bodyA } = await f.room(a.token);
  const { body: bodyB } = await f.room(b.token);
  const id = randomUUID();
  const path = `/room-submissions/${id}`;
  const first = await f.request('POST', '/room', a.token, { ...bodyA, submissionId: id });
  assert.equal(first.code, 10000);
  assert.deepEqual((await f.request('GET', path, b.token)).data, { state: 'unknown', createdId: '' });
  assert.notEqual((await f.request('POST', '/room', b.token, { ...bodyA, submissionId: id })).code, 10000);
  const second = await f.request('POST', '/room', b.token, { ...bodyB, submissionId: id });
  assert.equal(second.code, 10000);
  assert.notEqual(first.data.createdId, second.data.createdId);
  assert.equal((await f.request('PUT', `${path}/close`, b.token)).data.createdId, second.data.createdId);
  assert.equal((await f.request('GET', path, a.token)).data.createdId, first.data.createdId);
  assert.equal((await f.request('GET', path)).status, 401);
  assert.equal((await f.request('PUT', `${path}/close`)).status, 401);
});

test('room submission: stopping unknown blocks late creation and stopping created never deletes a house', async t => {
  const f = await fixture(t);
  const user = await f.login();
  const { body } = await f.room(user.token);
  const input = { ...body, submissionId: randomUUID() };
  const path = `/room-submissions/${input.submissionId}`;
  assert.deepEqual((await f.request('PUT', `${path}/close`, user.token)).data, { state: 'closed', createdId: '' });
  assert.equal((await f.request('POST', '/room', user.token, input)).code, 40903);
  assert.equal((await f.request('GET', '/room', user.token)).data.length, 1);
  const replacement = { ...body, submissionId: randomUUID() };
  const created = await f.request('POST', '/room', user.token, replacement);
  assert.equal(created.code, 10000);
  assert.deepEqual((await f.request('PUT', `/room-submissions/${replacement.submissionId}/close`, user.token)).data,
    { state: 'created', createdId: created.data.createdId });
  assert.equal((await f.request('GET', `/room/${created.data.createdId}`, user.token)).code, 10000);
});

test('room submission: creation racing stop has a stable terminal outcome', async t => {
  const f = await fixture(t);
  const user = await f.login();
  const { body } = await f.room(user.token);
  const input = { ...body, submissionId: randomUUID() };
  const path = `/room-submissions/${input.submissionId}`;
  const [created, stopped] = await Promise.all([
    f.request('POST', '/room', user.token, input),
    f.request('PUT', `${path}/close`, user.token),
  ]);
  const result = (await f.request('GET', path, user.token)).data;
  assert.deepEqual(stopped.data, result);
  if (result.state === 'created') assert.equal(created.data.createdId, result.createdId);
  else { assert.equal(result.state, 'closed'); assert.equal(created.code, 40903); }
  assert.equal((await f.request('GET', '/room', user.token)).data.length, result.state === 'created' ? 2 : 1);
});

test('room submission: deleted houses stay deleted after replay and reopening the database', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-room-receipt-'));
  const closers: (() => Promise<void>)[] = [];
  t.after(async () => { for (const close of closers) await close(); rmSync(directory, { recursive: true, force: true }); });
  const path = join(directory, 'test.sqlite');
  const first = await fixture(t, path);
  closers.push(first.close);
  const user = await first.login();
  const { body } = await first.room(user.token);
  const input = { ...body, submissionId: randomUUID() };
  const created = await first.request('POST', '/room', user.token, input);
  assert.equal(created.code, 10000);
  const saved = created.data.rows.find((row: { id: string }) => row.id === created.data.createdId);
  assert.equal((await first.request('DELETE', `/room/${created.data.createdId}`, user.token, { revision: saved.revision })).code, 10000);
  await first.close();
  const reopened = await fixture(t, path);
  closers.push(reopened.close);
  const receiptPath = `/room-submissions/${input.submissionId}`;
  const result = { state: 'deleted', createdId: created.data.createdId };
  assert.deepEqual((await reopened.request('GET', receiptPath, user.token)).data, result);
  assert.deepEqual((await reopened.request('PUT', `${receiptPath}/close`, user.token)).data, result);
  assert.equal((await reopened.request('POST', '/room', user.token, input)).code, 40904);
  assert.equal((await reopened.request('GET', '/room', user.token)).data.length, 1);
});

test('room submission: authoritative-list failure rolls back house receipt and photo bindings', async t => {
  const f = await fixture(t);
  const user = await f.login();
  const { body } = await f.room(user.token);
  const userId = String(f.store.one('SELECT id FROM users WHERE mobile=?', '13800138000')!.id);
  const bindings = Number(f.store.one('SELECT COUNT(*) AS n FROM upload_bindings')!.n);
  const service = new HousingService(f.store, f.config.publicBaseUrl);
  service.list = () => { throw new Error('room-list-failed'); };
  assert.throws(() => service.save(userId, { ...body, submissionId: randomUUID() }), /room-list-failed/);
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM rooms')!.n), 1);
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM room_submissions')!.n), 0);
  assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM upload_bindings')!.n), bindings);
});

test('room submission: version ten migration preserves data legacy creation and rejects malformed receipts', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-room-migration-'));
  const closers: (() => Promise<void>)[] = [];
  t.after(async () => { for (const close of closers) await close(); rmSync(directory, { recursive: true, force: true }); });
  const path = join(directory, 'test.sqlite');
  const original = await fixture(t, path);
  closers.push(original.close);
  const user = await original.login();
  const { body, record } = await original.room(user.token);
  original.store.db.exec('DROP TABLE IF EXISTS room_submissions; PRAGMA user_version=10');
  await original.close();
  const upgraded = await fixture(t, path);
  closers.push(upgraded.close);
  assert.equal(upgraded.store.one('PRAGMA user_version')!.user_version, 13);
  assert.equal((await upgraded.request('GET', `/room/${record.id}`, user.token)).code, 10000);
  assert.equal((await upgraded.request('POST', '/room', user.token, body)).code, 10000);
  assert.equal((await upgraded.request('POST', '/room', user.token, { ...body, submissionId: 'bad' })).code, 40000);
  assert.equal((await upgraded.request('GET', '/room-submissions/bad', user.token)).code, 40000);
});
