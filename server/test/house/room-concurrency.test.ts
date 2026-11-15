import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture } from '../helpers/api-fixture.js';

test('room edit concurrency: two resident edits accept only one version', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record, body } = await f.room(resident.token);
  const responses = await Promise.all(['102', '103'].map(room => f.request('POST', '/room', resident.token,
    { ...body, id: record.id, revision: record.revision, room })));
  assert.deepEqual(responses.map(response => response.status).sort(), [200, 409]);
  const winner = responses.find(response => response.code === 10000)!;
  assert.equal(winner.data.rows[0].revision, record.revision + 1);
  assert.equal(responses.find(response => response.status === 409)!.code, 40900);
  assert.deepEqual((await f.request('GET', `/room/${record.id}`, resident.token)).data, winner.data.rows[0]);
});

for (const decision of ['approve', 'reject']) {
  test(`room edit concurrency: stale edit preserves ${decision} result until explicit reload`, async t => {
    const f = await fixture(t);
    const resident = await f.login();
    const admin = await f.login('13800138090');
    f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
    const { record, body } = await f.room(resident.token);
    const review = await f.request('PUT', `/management/rooms/${record.id}/review`, admin.token,
      { revision: record.revision, decision, reason: decision === 'reject' ? '照片模糊' : '' });
    assert.equal(review.code, 10000);
    const stale = await f.request('POST', '/room', resident.token,
      { ...body, id: record.id, revision: record.revision, name: '李四' });
    assert.equal(stale.status, 409);
    assert.equal(stale.code, 40900);
    const latest = await f.request('GET', `/room/${record.id}`, resident.token);
    assert.deepEqual(latest.data, review.data);
    assert.equal(latest.data.revision, record.revision + 1);
    const updated = await f.request('POST', '/room', resident.token,
      { ...body, id: record.id, revision: latest.data.revision, name: '王五' });
    assert.equal(updated.code, 10000);
    assert.equal(updated.data.rows[0].revision, latest.data.revision + 1);
    assert.equal(updated.data.rows[0].status, 1);
    assert.equal(updated.data.rows[0].name, '王五');
    assert.equal(updated.data.rows[0].reviewReason, '');
    assert.equal(updated.data.rows[0].reviewedAt, '');
    assert.equal(updated.data.rows[0].reviewedBy, undefined);
  });
}

test('room edit concurrency: resident edit and property review cannot both win', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  const { record, body } = await f.room(resident.token);
  const responses = await Promise.all([
    f.request('POST', '/room', resident.token, { ...body, id: record.id, revision: record.revision, name: '李四' }),
    f.request('PUT', `/management/rooms/${record.id}/review`, admin.token, { revision: record.revision, decision: 'approve' }),
  ]);
  assert.deepEqual(responses.map(response => response.status).sort(), [200, 409]);
  const winner = responses.find(response => response.code === 10000)!;
  assert.deepEqual((await f.request('GET', `/room/${record.id}`, resident.token)).data,
    winner.data.rows?.[0] ?? winner.data);
});

test('room edit concurrency: missing and invalid versions never change the record', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record, body } = await f.room(resident.token);
  for (const revision of [undefined, null, '1', -1, 1.5, true, 0, 999, Number.MAX_SAFE_INTEGER + 1]) {
    const response = await f.request('POST', '/room', resident.token,
      { ...body, id: record.id, revision, room: '999' });
    assert.notEqual(response.code, 10000, `version ${String(revision)} must fail closed`);
    assert.deepEqual((await f.request('GET', `/room/${record.id}`, resident.token)).data, record);
  }
  const missing = await f.request('POST', '/room', resident.token, { ...body, id: record.id });
  assert.equal(missing.status, 409);
});

test('room edit concurrency: ownership is checked before version and deleted records stay deleted', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const stranger = await f.login('13800138001');
  const { record, body } = await f.room(resident.token);
  for (const revision of [undefined, 0, record.revision]) {
    const response = await f.request('POST', '/room', stranger.token, { ...body, id: record.id, revision });
    assert.equal(response.status, 404);
  }
  await f.request('DELETE', `/room/${record.id}`, resident.token, { revision: record.revision });
  const edited = await f.request('POST', '/room', resident.token, { ...body, id: record.id, revision: record.revision });
  assert.equal(edited.status, 404);
  assert.deepEqual((await f.request('GET', '/room', resident.token)).data, []);
});

test('room edit concurrency: legacy records use explicit zero and creation starts at one', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record, body } = await f.room(resident.token);
  const userId = String(f.store.one('SELECT id FROM users WHERE mobile = ?', '13800138000')!.id);
  const legacy = { ...record };
  delete legacy.revision;
  f.store.save('rooms', userId, legacy, true);
  assert.equal((await f.request('POST', '/room', resident.token, { ...body, id: record.id })).status, 409);
  const updated = await f.request('POST', '/room', resident.token, { ...body, id: record.id, revision: 0 });
  assert.equal(updated.code, 10000);
  assert.equal(updated.data.rows[0].revision, 1);
  const created = await f.request('POST', '/room', resident.token, { ...body, revision: 88 });
  assert.equal(created.code, 10000);
  assert.equal(created.data.rows.find((row: { id: string }) => row.id !== record.id).revision, 1);
});
