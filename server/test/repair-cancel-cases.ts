import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import type { ApiFixtureFactory } from './api.test.js';

export function registerRepairCancelTests(fixture: ApiFixtureFactory) {
  async function setup(t: TestContext) {
    const f = await fixture(t, ':memory:', () => Date.parse('2026-10-17T00:00:00Z'));
    const resident = await f.login();
    const admin = await f.login('13800138090');
    const worker = await f.login('13800138091');
    f.store.run("UPDATE users SET role='admin' WHERE mobile=?", '13800138090');
    f.store.run("UPDATE users SET role='worker' WHERE mobile=?", '13800138091');
    const workerId = String(f.store.one('SELECT id FROM users WHERE mobile=?', '13800138091')!.id);
    assert.ok(f.store.one("SELECT workerId FROM worker_skills WHERE workerId=? AND skill='plumbing'", workerId));
    const house = await f.room(resident.token);
    async function create() {
      const result = await f.request('POST', '/repair', resident.token, { houseId: house.record.id,
        repairItemId: '1004', mobile: '13800138000', expectedTime: '2026-10-20T10:00:00+08:00' });
      assert.equal(result.code, 10000);
      return (await f.request('GET', `/repair/${result.data.createdId}`, resident.token)).data;
    }
    return { ...f, resident, admin, worker, workerId, create };
  }

  test('repair cancellation: both routes reject missing or invalid versions without changing orders', async t => {
    const f = await setup(t);
    const row = await f.create();
    for (const path of [`/cancel/repair/${row.id}`, `/repair/${row.id}/revoke`]) {
      for (const body of [undefined, {}, { revision: row.revision + 1 }]) {
        const reply = await f.request('PUT', path, f.resident.token, body);
        assert.equal(reply.status, 409);
        assert.equal(reply.code, 40900);
        assert.deepEqual((await f.request('GET', `/repair/${row.id}`, f.resident.token)).data, row);
      }
      for (const revision of [null, true, '1', -1, 1.5, Number.MAX_SAFE_INTEGER + 1]) {
        assert.equal((await f.request('PUT', path, f.resident.token, { revision })).code, 40000);
        assert.deepEqual((await f.request('GET', `/repair/${row.id}`, f.resident.token)).data, row);
      }
    }
  });

  test('repair cancellation: stale cancellation preserves dispatch and explicit refreshed cancellation returns complete list', async t => {
    const f = await setup(t);
    const row = await f.create();
    const assigned = await f.request('PUT', `/management/repairs/${row.id}/assign`, f.admin.token,
      { revision: row.revision, workerId: f.workerId });
    assert.equal(assigned.code, 10000);
    const latest = (await f.request('GET', `/repair/${row.id}`, f.resident.token)).data;
    const stale = await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: row.revision });
    assert.equal(stale.status, 409);
    assert.deepEqual((await f.request('GET', `/repair/${row.id}`, f.resident.token)).data, latest);
    const cancelled = await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: latest.revision });
    assert.equal(cancelled.code, 10000);
    assert.equal(cancelled.data.complete, true);
    assert.equal(cancelled.data.total, 1);
    assert.equal(cancelled.data.rows[0].status, 0);
    assert.equal(cancelled.data.rows[0].revision, latest.revision + 1);
    assert.equal((await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: latest.revision })).status, 409);
  });

  test('repair cancellation: dispatch race has exactly one winner', async t => {
    for (const cancelFirst of [true, false]) {
      const f = await setup(t);
      const row = await f.create();
      const cancel = () => f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: row.revision });
      const assign = () => f.request('PUT', `/management/repairs/${row.id}/assign`, f.admin.token,
        { revision: row.revision, workerId: f.workerId });
      const replies = await Promise.all((cancelFirst ? [cancel, assign] : [assign, cancel]).map(run => run()));
      assert.equal(replies.filter(reply => reply.code === 10000).length, 1);
      assert.equal(replies.find(reply => reply.code !== 10000)!.status, 409);
    }
  });

  test('repair cancellation: direct route never creates a revocation request after worker acceptance', async t => {
    const f = await setup(t);
    const row = await f.create();
    const assigned = await f.request('PUT', `/management/repairs/${row.id}/assign`, f.admin.token,
      { revision: row.revision, workerId: f.workerId });
    assert.equal(assigned.code, 10000);
    const accepted = await f.request('PUT', `/worker/repairs/${row.id}/accept`, f.worker.token, { revision: assigned.data.revision });
    assert.equal(accepted.code, 10000);
    const latest = (await f.request('GET', `/repair/${row.id}`, f.resident.token)).data;
    assert.equal((await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: row.revision })).status, 409);
    const direct = await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token,
      { revision: latest.revision, reason: '需要撤销', notified: true });
    assert.equal(direct.code, 40001);
    assert.deepEqual((await f.request('GET', `/repair/${row.id}`, f.resident.token)).data, latest);
    const requested = await f.request('PUT', `/repair/${row.id}/revoke`, f.resident.token,
      { revision: latest.revision, reason: '需要撤销', notified: true });
    assert.equal(requested.code, 10000);
    assert.equal(requested.data.status, 2);
    assert.ok(requested.data.pendings.some((item: {kind:string}) => item.kind === 'revoke'));
  });

  test('repair cancellation: authorization precedes missing and stale version conflicts', async t => {
    const f = await setup(t);
    const other = await f.login('13800138001');
    const row = await f.create();
    for (const path of [`/cancel/repair/${row.id}`, `/repair/${row.id}/revoke`]) {
      assert.equal((await f.request('PUT', path, '', { revision: row.revision })).status, 401);
      for (const token of [other.token, f.worker.token]) {
        for (const body of [{}, { revision: row.revision + 1 }]) {
          assert.equal((await f.request('PUT', path, token, body)).status, 404);
        }
      }
    }
    assert.deepEqual((await f.request('GET', `/repair/${row.id}`, f.resident.token)).data, row);
  });

  test('repair cancellation: historical unversioned records require explicit zero', async t => {
    const f = await setup(t);
    const row = await f.create();
    const saved = f.store.one('SELECT userId,payload FROM repairs WHERE id=?', row.id)!;
    const legacy = JSON.parse(String(saved.payload));
    delete legacy.revision;
    f.store.save('repairs', String(saved.userId), legacy, true);
    assert.equal((await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, {})).status, 409);
    const cancelled = await f.request('PUT', `/cancel/repair/${row.id}`, f.resident.token, { revision: 0 });
    assert.equal(cancelled.code, 10000);
    assert.equal(cancelled.data.rows[0].revision, 1);
  });
}
