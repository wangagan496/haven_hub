import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { fixture, START, H, SLOT } from './repair-fixture.js';
import { Store } from '../../src/database.js';
import { RepairService } from '../../src/repair/service.js';

test('same submission survives lost response and concurrent retries without duplicate orders', async t => {
  const f = await fixture(t);
  const submissionId = randomUUID();
  const body = { ...f.body, submissionId, description: '漏水' };
  const first = await f.call('resident', 'POST', '/repair', body);
  const retries = await Promise.all(Array.from({ length: 5 }, () => f.call('resident', 'POST', '/repair', body)));
  for (const result of retries) {
    assert.equal(result.createdId, first.createdId);
    assert.equal(result.complete, true);
    assert.equal(result.total, 1);
  }
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repairs')!.n, 1);
  const receipt = await f.call('resident', 'GET', `/repair-submissions/${submissionId}`);
  assert.deepEqual(receipt, { state: 'created', createdId: first.createdId });
  assert.equal('submissionId' in f.store.get('repairs', f.ids.resident, first.createdId)!, false);
});

test('changed contents reject the original key, including after 24 hours; unrelated keys remain independent', async t => {
  const f = await fixture(t);
  const submissionId = randomUUID();
  const first = await f.call('resident', 'POST', '/repair', { ...f.body, submissionId });
  const conflict = await f.raw('resident', 'POST', '/repair', { ...f.body, submissionId, description: '不同内容' });
  assert.equal(conflict.status, 409);
  assert.equal(conflict.code, 40902);
  f.at(START + 48 * H);
  assert.equal((await f.call('resident', 'POST', '/repair', { ...f.body, submissionId })).createdId, first.createdId);
  assert.equal((await f.call('resident', 'POST', '/repair', { ...f.body, submissionId: randomUUID() })).total, 2);
});

test('receipt lookup is authenticated, owner scoped and cannot be used by staff', async t => {
  const f = await fixture(t);
  const submissionId = randomUUID();
  await f.call('resident', 'POST', '/repair', { ...f.body, submissionId });
  const unknown = { state: 'unknown', createdId: '' };
  assert.deepEqual(await f.call('other', 'GET', `/repair-submissions/${submissionId}`), unknown);
  assert.deepEqual(await f.call('resident', 'GET', `/repair-submissions/${randomUUID()}`), unknown);
  assert.equal((await f.raw(undefined, 'GET', `/repair-submissions/${submissionId}`)).status, 401);
  assert.equal((await f.raw('worker', 'GET', `/repair-submissions/${submissionId}`)).status, 403);
  assert.equal((await f.raw('resident', 'GET', '/repair-submissions/not-a-uuid')).code, 40000);
  const otherHouse = randomUUID();
  f.store.save('rooms', f.ids.other, { id: otherHouse, point: '乙小区', building: '1', room: '1' });
  const other = await f.call('other', 'POST', '/repair', { ...f.body, houseId: otherHouse, submissionId });
  assert.equal(other.total, 1);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repairs')!.n, 2);
});

test('retrying a committed timed booking bypasses new-booking capacity and time checks', async t => {
  const f = await fixture(t);
  await f.capacities(1);
  const body = { ...f.body, slot: SLOT, submissionId: randomUUID() };
  const first = await f.call('resident', 'POST', '/repair', body);
  assert.equal((await f.call('resident', 'POST', '/repair', body)).createdId, first.createdId);
  f.at(START + 72 * H);
  assert.equal((await f.call('resident', 'POST', '/repair', body)).createdId, first.createdId);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repairs')!.n, 1);
});

test('creation and receipt roll back together when response assembly fails', async t => {
  const f = await fixture(t);
  const service = new RepairService(f.store, f.time, '020-88888888');
  const body = { ...f.body, submissionId: randomUUID() };
  assert.throws(() => service.createRepair(f.ids.resident, body, () => { throw new Error('list failed'); }), /list failed/);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repairs')!.n, 0);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repair_submissions')!.n, 0);
  assert.equal(service.createRepair(f.ids.resident, body).total, 1);
});

test('closing unknown submission fences late creates, is repeatable and never cancels existing orders', async t => {
  const f = await fixture(t);
  const submissionId = randomUUID();
  const path = `/repair-submissions/${submissionId}`;
  assert.deepEqual(await f.call('resident', 'PUT', `${path}/close`), { state: 'closed', createdId: '' });
  assert.deepEqual(await f.call('resident', 'PUT', `${path}/close`), { state: 'closed', createdId: '' });
  assert.equal((await f.raw('resident', 'POST', '/repair', { ...f.body, submissionId })).code, 40903);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM repairs')!.n, 0);
  const next = randomUUID();
  const first = await f.call('resident', 'POST', '/repair', { ...f.body, submissionId: next });
  assert.deepEqual(await f.call('resident', 'PUT', `/repair-submissions/${next}/close`), { state: 'created', createdId: first.createdId });
  assert.equal((await f.call('resident', 'GET', `/repair/${first.createdId}`)).status, 1);
  assert.deepEqual(await f.call('other', 'GET', path), { state: 'unknown', createdId: '' });
});

test('persistent receipt survives process store reopen and version seven migration preserves existing data', () => {
  const root = mkdtempSync(join(tmpdir(), 'haven-submission-'));
  const path = join(root, 'test.sqlite');
  let store = new Store(path);
  try {
    const userId = randomUUID();
    const houseId = randomUUID();
    store.run('INSERT INTO users(id,mobile,nickName) VALUES (?,?,?)', userId, '13800138000', '测试');
    store.save('rooms', userId, { id: houseId, point: '测试小区', building: '1', room: '1' });
    store.db.exec('DROP TABLE IF EXISTS repair_submissions; PRAGMA user_version = 7');
    store.close();
    store = new Store(path);
    assert.equal(store.one('PRAGMA user_version')!.user_version, 13);
    const input = { houseId, mobile: '13800138000', repairItemId: '1004', submissionId: randomUUID() };
    const first = new RepairService(store, () => START, '020-88888888').createRepair(userId, input);
    store.close();
    store = new Store(path);
    const result = new RepairService(store, () => START + 48 * H, '020-88888888').createRepair(userId, input);
    assert.equal(result.createdId, first.createdId);
    assert.equal(result.total, 1);
    assert.equal(store.get('rooms', userId, houseId)?.point, '测试小区');
  } finally {
    store.close();
    rmSync(root, { recursive: true, force: true });
  }
});
