import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { CommunityService } from '../src/community/service.js';
import type { ApiFixtureFactory } from './api.test.js';

const bodyFor = (houseId: string, submissionId: string = randomUUID()) => ({
  submissionId, houseId, name: '访客甲', gender: 1, mobile: '13800138000', visitDate: '2026-10-28',
});

export function registerVisitorSubmissionTests(fixture: ApiFixtureFactory) {
  test('visitor submission: concurrent retries create one invitation and one image', async t => {
    const f = await fixture(t);
    const user = await f.login();
    const house = await f.room(user.token);
    const before = Number(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n);
    const body = bodyFor(house.record.id);
    const replies = await Promise.all(Array.from({ length: 4 }, () => f.request('POST', '/visitor', user.token, body)));
    const first = replies[0];
    assert.ok(first);
    for (const reply of replies) {
      assert.equal(reply.code, 10000);
      assert.equal(reply.data.rows.length, 1);
      assert.equal(reply.data.createdId, first.data.createdId);
    }
    assert.ok(first.data.createdId);
    assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n), before + 1);
    const replay = await f.request('POST', '/visitor', user.token, body);
    assert.equal(replay.data.createdId, first.data.createdId);
    assert.deepEqual((await f.request('GET', `/visitor-submissions/${body.submissionId}`, user.token)).data,
      { state: 'created', createdId: replay.data.createdId });
  });

  test('visitor submission: changed content is rejected and original invitation stays unchanged', async t => {
    const f = await fixture(t);
    const user = await f.login();
    const house = await f.room(user.token);
    const body = bodyFor(house.record.id);
    const first = await f.request('POST', '/visitor', user.token, body);
    assert.equal(first.code, 10000);
    for (const change of [{ name: '访客乙' }, { visitDate: '2026-10-29' }, { mobile: '13800138001' }, { gender: 0 }]) {
      const reply = await f.request('POST', '/visitor', user.token, { ...body, ...change });
      assert.equal(reply.status, 409);
      assert.equal(reply.code, 40902);
    }
    assert.deepEqual((await f.request('GET', '/visitor', user.token)).data.rows, first.data.rows);
  });

  test('visitor submission: receipt lookup and close are account scoped', async t => {
    const f = await fixture(t);
    const a = await f.login();
    const b = await f.login('13800138001');
    const houseA = await f.room(a.token);
    const houseB = await f.room(b.token);
    const body = bodyFor(houseA.record.id);
    const first = await f.request('POST', '/visitor', a.token, body);
    const path = `/visitor-submissions/${body.submissionId}`;
    assert.deepEqual((await f.request('GET', path, b.token)).data, { state: 'unknown', createdId: '' });
    const second = await f.request('POST', '/visitor', b.token, { ...body, houseId: houseB.record.id });
    assert.equal(second.code, 10000);
    assert.notEqual(second.data.createdId, first.data.createdId);
    assert.equal((await f.request('GET', path, a.token)).data.createdId, first.data.createdId);
    assert.equal((await f.request('PUT', `${path}/close`, b.token)).data.createdId, second.data.createdId);
    assert.equal((await f.request('GET', `/visitor/${first.data.createdId}`, b.token)).status, 404);
    assert.equal((await f.request('GET', path)).status, 401);
  });

  test('visitor submission: closing unknown blocks late creation and never cancels a created invitation', async t => {
    const f = await fixture(t);
    const user = await f.login();
    const house = await f.room(user.token);
    const body = bodyFor(house.record.id);
    const path = `/visitor-submissions/${body.submissionId}`;
    assert.deepEqual((await f.request('PUT', `${path}/close`, user.token)).data, { state: 'closed', createdId: '' });
    const late = await f.request('POST', '/visitor', user.token, body);
    assert.equal(late.code, 40903);
    assert.deepEqual((await f.request('GET', '/visitor', user.token)).data.rows, []);
    const replacement = bodyFor(house.record.id);
    const created = await f.request('POST', '/visitor', user.token, replacement);
    assert.equal(created.code, 10000);
    assert.equal((await f.request('PUT', `/visitor-submissions/${replacement.submissionId}/close`, user.token)).data.createdId, created.data.createdId);
    assert.equal((await f.request('GET', `/visitor/${created.data.createdId}`, user.token)).data.status, 1);
  });

  test('visitor submission: create racing close has one stable outcome', async t => {
    const f = await fixture(t);
    const user = await f.login();
    const house = await f.room(user.token);
    const body = bodyFor(house.record.id);
    const path = `/visitor-submissions/${body.submissionId}`;
    const [create, close] = await Promise.all([
      f.request('POST', '/visitor', user.token, body), f.request('PUT', `${path}/close`, user.token),
    ]);
    const outcome = (await f.request('GET', path, user.token)).data;
    assert.deepEqual(close.data, outcome);
    const rows = (await f.request('GET', '/visitor', user.token)).data.rows;
    if (outcome.state === 'created') {
      assert.equal(create.code, 10000);
      assert.equal(rows.length, 1);
      assert.equal(rows[0].id, outcome.createdId);
    } else {
      assert.equal(outcome.state, 'closed');
      assert.equal(create.code, 40903);
      assert.deepEqual(rows, []);
    }
  });

  test('visitor submission: replay survives deleted house and database restart', async t => {
    const directory = mkdtempSync(join(tmpdir(), 'haven-visitor-receipt-'));
    const closers: (() => Promise<void>)[] = [];
    t.after(async () => { for (const close of closers) await close(); rmSync(directory, { recursive: true, force: true }); });
    const path = join(directory, 'test.sqlite');
    const first = await fixture(t, path);
    closers.push(first.close);
    const user = await first.login();
    const house = await first.room(user.token);
    const body = bodyFor(house.record.id);
    const created = await first.request('POST', '/visitor', user.token, body);
    assert.equal(created.code, 10000);
    assert.equal((await first.request('DELETE', `/room/${house.record.id}`, user.token, { revision: house.record.revision })).code, 10000);
    await first.close();
    const reopened = await fixture(t, path);
    closers.push(reopened.close);
    const replay = await reopened.request('POST', '/visitor', user.token, body);
    assert.equal(replay.code, 10000);
    assert.equal(replay.data.createdId, created.data.createdId);
    assert.equal(replay.data.rows.length, 1);
    await reopened.close();
  });

  test('visitor submission: failed authoritative list rolls back receipt, visitor and image', async t => {
    const f = await fixture(t);
    const user = await f.login();
    const house = await f.room(user.token);
    const userId = String(f.store.one('SELECT id FROM users WHERE mobile=?', '13800138000')!.id);
    const service = new CommunityService(f.store, f.config.publicBaseUrl);
    const body = bodyFor(house.record.id);
    const before = Number(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n);
    service.list = () => { throw new Error('injected visitor list failure'); };
    assert.throws(() => service.createVisitor(userId, body, new Uint8Array([1, 2]), 'rollback-image'), /injected visitor list failure/);
    assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM uploads')!.n), before);
    assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM visitors')!.n), 0);
    assert.equal(Number(f.store.one('SELECT COUNT(*) AS n FROM visitor_submissions')!.n), 0);
  });

  test('visitor submission: migration from nine preserves data and rejects malformed receipts', async t => {
    const directory = mkdtempSync(join(tmpdir(), 'haven-visitor-migration-'));
    const closers: (() => Promise<void>)[] = [];
    t.after(async () => { for (const close of closers) await close(); rmSync(directory, { recursive: true, force: true }); });
    const path = join(directory, 'test.sqlite');
    const original = await fixture(t, path);
    closers.push(original.close);
    const user = await original.login();
    const house = await original.room(user.token);
    original.store.db.exec('DROP TABLE IF EXISTS visitor_submissions; PRAGMA user_version=9');
    await original.close();
    const migrated = await fixture(t, path);
    closers.push(migrated.close);
    assert.equal(migrated.store.one('PRAGMA user_version')!.user_version, 13);
    assert.equal((await migrated.request('GET', `/room/${house.record.id}`, user.token)).data.id, house.record.id);
    assert.equal((await migrated.request('POST', '/visitor', user.token, bodyFor(house.record.id, 'bad'))).code, 40000);
    const { submissionId: _, ...legacy } = bodyFor(house.record.id);
    assert.equal((await migrated.request('POST', '/visitor', user.token, legacy)).code, 10000);
    await migrated.close();
  });
}
