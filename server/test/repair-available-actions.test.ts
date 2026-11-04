import test from 'node:test';
import assert from 'node:assert/strict';
import { fixture, H, type Row } from './repair-fixture.js';
import { confirmationAvailability } from '../src/repair/policy.js';
import { confirm } from '../src/repair/actions.js';
import { newRound } from '../src/repair/model.js';
import type { RecordData } from '../src/database.js';

test('confirmation display is read-only and agrees with execution for normal and legacy records', () => {
  const scenarios: { status: number; ready?: boolean; revoke?: boolean; enabled: boolean }[] = [
    { status: 1, enabled: false }, { status: 5, enabled: false },
    { status: 2, enabled: false }, { status: 2, ready: true, enabled: true },
    { status: 2, ready: true, revoke: true, enabled: false },
    { status: 6, enabled: true }, { status: 6, revoke: true, enabled: false },
    { status: 3, enabled: false }, { status: 0, enabled: false }, { status: 4, enabled: false },
  ];
  for (const scenario of scenarios) {
    const record: RecordData = { id: 'decision', status: scenario.status,
      ...(scenario.ready ? { rounds: [{ ...newRound(1, '首次维修', ''), resultSavedAt: '2026-10-17T00:00:00Z', note: '已修好', cost: 0 }] } : {}),
      pendings: scenario.revoke ? [{ id: 'revoke', kind: 'revoke', by: 'resident', at: '', reason: '撤销' }] : [],
    };
    const original = structuredClone(record);
    assert.equal(confirmationAvailability(record, 'resident').enabled, scenario.enabled);
    assert.equal(confirmationAvailability(record, 'worker').reasonCode, 'resident_only');
    assert.equal(confirmationAvailability(record, 'admin').reasonCode, 'resident_only');
    assert.deepEqual(record, original);
    if (scenario.enabled) assert.doesNotThrow(() => confirm(record, {}, Date.parse('2026-10-17T08:00:00Z')));
    else assert.throws(() => confirm(record, {}, Date.parse('2026-10-17T08:00:00Z')));
  }
});

function confirmation(row: Row) {
  assert(Array.isArray(row.availableActions), '详情必须给出服务端操作判断');
  const action = row.availableActions.find((item: Row) => item.code === 'confirm');
  assert(action, '确认动作必须包含可用状态和原因');
  assert.deepEqual(Object.keys(action).sort(), ['code', 'enabled', 'reasonCode']);
  return action;
}

test('confirmation availability follows saved result and role across lists, details and mutation responses', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  assert.deepEqual(confirmation(await f.detail(row)), { code: 'confirm', enabled: false, reasonCode: 'result_not_ready' });
  row = await f.change('worker', row, 'result', { ready: true, result: '维修完成，已现场检查', cost: 0 });
  assert.deepEqual(confirmation(row), { code: 'confirm', enabled: false, reasonCode: 'resident_only' });
  assert.equal(confirmation(await f.detail(row)).enabled, true);
  const listed = await f.call('resident', 'GET', '/repair');
  assert.equal(confirmation(listed.rows.find((item: Row) => item.id === row.id)).enabled, true);
  const managed = await f.call('admin', 'GET', '/management/repairs');
  const adminRows = Array.isArray(managed) ? managed : managed.rows;
  assert.equal(confirmation(adminRows.find((item: Row) => item.id === row.id)).reasonCode, 'resident_only');
  const confirmed = await f.change('resident', row, 'confirm');
  assert.equal(confirmed.status, 3);
  assert.deepEqual(confirmation(confirmed), { code: 'confirm', enabled: false, reasonCode: 'already_completed' });
});

test('old enabled snapshot and forged action metadata cannot bypass ownership, revision or current result requirements', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('worker', row, 'result', { ready: true, result: '可确认结果', cost: 0 });
  const snapshot = await f.detail(row);
  assert.equal(confirmation(snapshot).enabled, true);
  const foreign = await f.raw('other', 'PUT', `/repair/${row.id}/confirm`, { revision: row.revision });
  assert.equal(foreign.status, 404);
  const forged = await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, {
    revision: row.revision, availableActions: [{ code: 'confirm', enabled: true, reasonCode: '' }],
  });
  assert.notEqual(forged.code, 10000);
  row = await f.change('worker', row, 'result', { ready: false, result: '仍在检查', cost: 0 });
  assert.equal((await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, { revision: snapshot.revision })).status, 409);
  assert.equal(confirmation(await f.detail(row)).reasonCode, 'result_not_ready');
  assert.notEqual((await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, { revision: row.revision })).code, 10000);
  assert.equal((await f.detail(row)).status, 2);
});

test('open revoke blocks confirmation even in a historical confirming state', async t => {
  const f = await fixture(t);
  const row = await f.processing();
  f.store.save('repairs', f.ids.resident, { ...f.stored(row), status: 6,
    pendings: [{ id: 'revoke', kind: 'revoke', by: 'resident', at: new Date(f.time()).toISOString(), reason: '待回应' }],
  }, true);
  const detail = await f.detail(row);
  assert.deepEqual(confirmation(detail), { code: 'confirm', enabled: false, reasonCode: 'revoke_pending' });
  const rejected = await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, { revision: detail.revision });
  assert.match(rejected.message, /先处理撤销/);
  assert.equal((await f.detail(row)).status, 6);
});

test('expiry is settled before action display and an old enabled snapshot cannot confirm twice', async t => {
  const f = await fixture(t);
  let row = await f.processing();
  row = await f.change('worker', row, 'complete', { result: '已完成', cost: 0 });
  assert.equal(confirmation(await f.detail(row)).enabled, true);
  f.at(f.time() + 72 * H);
  assert.equal((await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`, { revision: row.revision })).status, 409);
  const detail = await f.detail(row);
  assert.equal(confirmation(detail).reasonCode, 'already_completed');
  assert.equal(detail.timeline.filter((item: Row) => item.action === 'auto_confirmed').length, 1);
});
