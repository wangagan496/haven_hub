import test from 'node:test';
import assert from 'node:assert/strict';
import { HousingService } from '../../src/housing/service.js';
import { fixture } from '../helpers/api-fixture.js';

test('room deletion: stale detail cannot delete a later edit or property review', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  for (const action of ['edit', 'approve', 'reject']) {
    const { record, body } = await f.room(resident.token);
    const changed = action === 'edit'
      ? await f.request('POST', '/room', resident.token, { ...body, id: record.id, revision: record.revision, name: '李四' })
      : await f.request('PUT', `/management/rooms/${record.id}/review`, admin.token,
        { revision: record.revision, decision: action, reason: action === 'reject' ? '请核对照片' : '' });
    assert.equal(changed.code, 10000);
    const latest = (await f.request('GET', `/room/${record.id}`, resident.token)).data;
    const stale = await f.request('DELETE', `/room/${record.id}`, resident.token, { revision: record.revision });
    assert.equal(stale.status, 409);
    assert.equal(stale.code, 40900);
    assert.deepEqual((await f.request('GET', `/room/${record.id}`, resident.token)).data, latest);
    assert.equal((await f.request('DELETE', `/room/${record.id}`, resident.token, { revision: latest.revision })).code, 10000);
  }
});

test('room deletion: missing and invalid versions fail without deleting', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record } = await f.room(resident.token);
  const path = `/room/${record.id}`;
  for (const body of [undefined, {}, { revision: 0 }, { revision: 999 }]) {
    const reply = await f.request('DELETE', path, resident.token, body);
    assert.equal(reply.status, 409);
    assert.equal(reply.code, 40900);
    assert.deepEqual((await f.request('GET', path, resident.token)).data, record);
  }
  for (const revision of [null, '1', -1, 1.5, true, Number.MAX_SAFE_INTEGER + 1]) {
    const reply = await f.request('DELETE', path, resident.token, { revision });
    assert.equal(reply.code, 40000);
    assert.deepEqual((await f.request('GET', path, resident.token)).data, record);
  }
  assert.equal((await f.request('DELETE', path, resident.token, { revision: record.revision, userId: 'forged' })).code, 40000);
  assert.deepEqual((await f.request('GET', path, resident.token)).data, record);
});

test('room deletion: concurrent edit or review and deletion cannot both succeed', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const admin = await f.login('13800138090');
  f.store.run("UPDATE users SET role = 'admin' WHERE mobile = ?", '13800138090');
  for (const action of ['edit', 'approve']) {
    for (const deleteFirst of [true, false]) {
      const { record, body } = await f.room(resident.token);
      const change = () => action === 'edit'
        ? f.request('POST', '/room', resident.token, { ...body, id: record.id, revision: record.revision, name: '王五' })
        : f.request('PUT', `/management/rooms/${record.id}/review`, admin.token, { revision: record.revision, decision: 'approve' });
      const remove = () => f.request('DELETE', `/room/${record.id}`, resident.token, { revision: record.revision });
      const replies = await Promise.all((deleteFirst ? [remove, change] : [change, remove]).map(run => run()));
      assert.equal(replies.filter(reply => reply.code === 10000).length, 1);
      assert.ok(replies.some(reply => reply.status === 409 || reply.status === 404));
      const deleted = replies[deleteFirst ? 0 : 1]!.code === 10000;
      const final = await f.request('GET', `/room/${record.id}`, resident.token);
      if (deleted) assert.equal(final.status, 404);
      else assert.equal(final.data.revision, record.revision + 1);
    }
  }
});

test('room deletion: authorization precedes version checks and repeated deletion stays missing', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const stranger = await f.login('13800138001');
  const { record } = await f.room(resident.token);
  const path = `/room/${record.id}`;
  assert.equal((await f.request('DELETE', path, '', { revision: record.revision })).status, 401);
  for (const revision of [undefined, 0, record.revision]) {
    assert.equal((await f.request('DELETE', path, stranger.token, { revision })).status, 404);
  }
  assert.deepEqual((await f.request('GET', path, resident.token)).data, record);
  const replies = await Promise.all([1, 2].map(() => f.request('DELETE', path, resident.token, { revision: record.revision })));
  assert.deepEqual(replies.map(reply => reply.status).sort(), [200, 404]);
  assert.deepEqual(replies.find(reply => reply.code === 10000)!.data, { complete: true, rows: [], total: 0 });
  assert.equal((await f.request('DELETE', path, resident.token, { revision: record.revision })).status, 404);
});

test('room deletion: historical record requires explicit zero', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record } = await f.room(resident.token);
  const userId = String(f.store.one('SELECT id FROM users WHERE mobile=?', '13800138000')!.id);
  const legacy = { ...record };
  delete legacy.revision;
  f.store.save('rooms', userId, legacy, true);
  assert.equal((await f.request('DELETE', `/room/${record.id}`, resident.token)).status, 409);
  assert.equal((await f.request('DELETE', `/room/${record.id}`, resident.token, { revision: 0 })).code, 10000);
});

test('room deletion: authoritative list failure rolls back deletion', async t => {
  const f = await fixture(t);
  const resident = await f.login();
  const { record } = await f.room(resident.token);
  const original = HousingService.prototype.list;
  HousingService.prototype.list = () => { throw new Error('injected room deletion list failure'); };
  try {
    assert.equal((await f.request('DELETE', `/room/${record.id}`, resident.token, { revision: record.revision })).status, 500);
  } finally { HousingService.prototype.list = original; }
  assert.deepEqual((await f.request('GET', `/room/${record.id}`, resident.token)).data, record);
});
