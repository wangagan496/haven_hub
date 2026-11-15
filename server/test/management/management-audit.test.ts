import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../../src/database.js';
import { ManagementAudit } from '../../src/management-audit.js';
import { createBackup, restoreBackup } from '../../src/backup.js';
import { Status, newRound } from '../../src/repair/model.js';
import { fixture, START, NEXT, type Row } from '../repair/repair-fixture.js';

test('management changes record the authenticated actor and necessary before/after fields', async t => {
  const f = await fixture(t);
  let repair = await f.create();
  repair = await f.change('admin', repair, 'priority', { priority: 'medium', reason: '业务原因' });
  repair = await f.change('admin', repair, 'assign', { workerId: f.ids.worker });
  const result = await f.call('admin', 'GET', `/management/audit-events?actorId=${f.ids.admin}&targetId=${repair.id}`);
  assert.equal(result.rows.length, 2);
  const [assignment, priority] = result.rows;
  assert.equal(assignment.action, 'repair.assign');
  assert.equal(assignment.actorId, f.ids.admin);
  assert.equal(assignment.actorRole, 'admin');
  assert.equal(assignment.before.workerId, '');
  assert.equal(assignment.after.workerId, f.ids.worker);
  assert.equal(priority.before.priority, '');
  assert.equal(priority.after.priority, 'medium');
  assert.equal(result.nextCursor, null);
});

test('each worker skill change is retained while a preview creates no event', async t => {
  const f = await fixture(t);
  const path = '/worker/skills';
  const first = await f.call('worker', 'PUT', path, { workforceRevision: 0, skills: ['doors', 'electrical', 'plumbing'] });
  const preview = await f.call('worker', 'PUT', path, { workforceRevision: first.workforceRevision, skills: ['doors'], preview: true });
  assert.equal((await f.call('admin', 'GET', `/management/audit-events?targetId=${f.ids.worker}`)).rows.length, 1);
  await f.call('worker', 'PUT', path, { workforceRevision: first.workforceRevision, skills: ['doors'], previewToken: preview.previewToken });
  const result = await f.call('admin', 'GET', `/management/audit-events?action=worker.skills&targetId=${f.ids.worker}`);
  assert.equal(result.rows.length, 2);
  assert.equal(result.rows[0].actorId, f.ids.worker);
  assert.deepEqual(result.rows[0].before.skills, ['doors', 'electrical', 'plumbing']);
  assert.deepEqual(result.rows[0].after.skills, ['doors']);
  assert(result.rows[0].seq > result.rows[1].seq);
});

test('room review audit contains status transitions but no resident documents or free text', async t => {
  const f = await fixture(t);
  const room = { id: 'audit-room', status: 1, revision: 4, name: '私密住户姓名', mobile: '13911112222',
    idcardFrontUrl: '/media/private-identity', description: 'secret-credential-value' };
  f.store.save('rooms', f.ids.resident, room);
  await f.call('admin', 'PUT', '/management/rooms/audit-room/review', { revision: 4, decision: 'reject', reason: '13911112222 secret-credential-value' });
  const result = await f.call('admin', 'GET', '/management/audit-events?targetType=room&targetId=audit-room');
  assert.equal(result.rows.length, 1);
  assert.equal(result.rows[0].before.status, 1);
  assert.equal(result.rows[0].after.status, 3);
  assert.equal(result.rows[0].after.revision, 5);
  assert.doesNotMatch(JSON.stringify(result), /13911112222|私密住户姓名|private-identity|secret-credential-value/);
});

test('audit query enforces administrator access, validates inputs and parameterizes filters', async t => {
  const f = await fixture(t);
  for (const role of [undefined, 'resident', 'worker'] as const) {
    assert.equal((await f.raw(role, 'GET', '/management/audit-events')).status, role ? 403 : 401);
  }
  for (const query of ['limit=0','limit=101','before=-1','before=1.2','before=9007199254740992',
    'action=arbitrary','targetType=users','actorId=a&actorId=b','unknown=1']) {
    assert.equal((await f.raw('admin', 'GET', '/management/audit-events?' + query)).code, 40000, query);
  }
  const row = await f.create();
  await f.change('admin', row, 'priority', { priority: 'medium', reason: '有效操作' });
  assert.deepEqual((await f.call('admin', 'GET', '/management/audit-events?actorId=' + encodeURIComponent("' OR 1=1 --"))).rows, []);
  const forged = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/priority`,
    { revision: row.revision, priority: 'light', reason: '伪造', actorId: f.ids.other });
  assert.equal(forged.code, 40000);
  assert.equal((await f.call('admin', 'GET', '/management/audit-events')).rows.length, 1);
});

test('audit insert failure rolls back the business update and its notification writes', async t => {
  const f = await fixture(t);
  let repair = await f.create();
  repair = await f.detail(repair);
  const snapshot = () => ({ repairs: f.store.db.prepare('SELECT * FROM repairs ORDER BY seq').all(),
    notifications: f.store.db.prepare('SELECT * FROM notifications ORDER BY id').all(),
    deliveries: f.store.db.prepare('SELECT * FROM push_deliveries ORDER BY notificationId,deviceId').all() });
  const before = snapshot();
  f.store.db.exec("CREATE TRIGGER injected_audit_failure BEFORE INSERT ON management_audit BEGIN SELECT RAISE(ABORT,'audit unavailable'); END");
  assert.equal((await f.raw('admin', 'PUT', `/management/repairs/${repair.id}/priority`,
    { revision: repair.revision, priority: 'medium', reason: '不应提交' })).status, 500);
  assert.deepEqual(snapshot(), before);
  assert.equal((await f.call('admin', 'GET', '/management/audit-events')).rows.length, 0);
  f.store.db.exec('DROP TRIGGER injected_audit_failure');
  await f.change('admin', repair, 'priority', { priority: 'medium', reason: '恢复后成功' });
  assert.equal((await f.call('admin', 'GET', '/management/audit-events')).rows.length, 1);
});

test('a failed admin mutation keeps independently committed expiry settlement and does not invent an admin event', async t => {
  const f = await fixture(t);
  const round = newRound(1, '首次维修', new Date(START - 3600000).toISOString());
  round.confirmDeadline = new Date(START).toISOString();
  round.completedAt = new Date(START - 3600000).toISOString();
  f.store.save('repairs', f.ids.resident, { id: 'expires-before-action', status: Status.confirming, revision: 1,
    workerId: f.ids.worker, repairItemId: '1004', rounds: [round], timeline: [], pendings: [] });
  const result = await f.raw('admin', 'POST', '/management/repairs/expires-before-action/notes', { revision: 1, content: '旧版本备注' });
  assert.equal(result.status, 409);
  assert.equal(f.store.get('repairs', f.ids.resident, 'expires-before-action')!.status, Status.completed);
  assert.equal(f.store.get('repairs', f.ids.resident, 'expires-before-action')!.revision, 2);
  assert.deepEqual((await f.call('admin', 'GET', '/management/audit-events')).rows, []);
});

test('worker creation, leave and account changes are append-only and transactional', async t => {
  const f = await fixture(t);
  const workers = await f.call('admin', 'POST', '/management/workers', { mobile: '13911112222', nickName: '审计师傅' });
  let worker = workers.find((row: Row) => row.mobile === '13911112222');
  const target = `/management/workers/${worker.id}`;
  await f.call('admin', 'POST', target + '/leave', { revision: worker.revision, date: '2026-10-20', reason: '私密原因', preview: true });
  assert.equal((await f.call('admin', 'GET', '/management/audit-events')).rows.length, 1);
  worker = (await f.call('admin', 'POST', target + '/leave', { revision: worker.revision, date: '2026-10-20', reason: '私密原因' })).find((row: Row) => row.id === worker.id);
  worker = (await f.call('admin', 'DELETE', target + '/leave', { revision: worker.revision, date: '2026-10-20' })).find((row: Row) => row.id === worker.id);
  worker = (await f.call('admin', 'PUT', target + '/access', { revision: worker.revision, enabled: false, reason: '测试停用' })).find((row: Row) => row.id === worker.id);
  await f.call('admin', 'PUT', target + '/access', { revision: worker.revision, enabled: true, reason: '测试恢复' });
  const rows = (await f.call('admin', 'GET', `/management/audit-events?targetId=${worker.id}`)).rows;
  assert.deepEqual(rows.map((row: Row) => row.action), ['worker.access','worker.access','worker.leave.remove','worker.leave.save','worker.save']);
  assert.equal(rows[4].before, null);
  assert.equal(rows[0].before.enabled, false);
  assert.equal(rows[0].after.enabled, true);
  assert.doesNotMatch(JSON.stringify(rows), /13911112222|审计师傅|私密原因|测试停用/);
  assert.throws(() => f.store.run('UPDATE management_audit SET actorId=? WHERE seq=?', 'forged', rows[0].seq), /append-only/);
  assert.throws(() => f.store.run('DELETE FROM management_audit WHERE seq=?', rows[0].seq), /append-only/);
  f.store.db.exec("CREATE TRIGGER injected_audit_failure BEFORE INSERT ON management_audit BEGIN SELECT RAISE(ABORT,'audit unavailable'); END");
  assert.equal((await f.raw('admin', 'POST', '/management/workers', { mobile: '13911113333', nickName: '不得创建' })).status, 500);
  assert.equal(f.store.one('SELECT id FROM users WHERE mobile=?', '13911113333'), undefined);
});

test('admin reschedule conflict records its committed invalidation even when HTTP returns 409', async t => {
  const f = await fixture(t);
  await f.capacities(1, '11');
  let row = await f.processing();
  row = await f.change('worker', row, 'reschedule', { slot: NEXT, reason: '调整时间', notified: true }, 'POST');
  await f.create(NEXT);
  const result = await f.raw('admin', 'PUT', `/management/repairs/${row.id}/reschedule`, { revision: row.revision, accept: true });
  assert.equal(result.status, 409);
  assert.equal(f.stored(row).pendings[0].resolution, 'conflict');
  const events = (await f.call('admin', 'GET', `/management/audit-events?targetId=${row.id}&action=repair.reschedule.respond`)).rows;
  assert.equal(events.length, 1);
  assert.equal(events[0].actorId, f.ids.admin);
  assert.equal(events[0].before.pendingCounts.reschedule.open, 1);
  assert.equal(events[0].after.pendingCounts.reschedule.open, 0);
  assert.equal(events[0].after.revision, f.stored(row).revision);
});

test('audit failure rolls back room review and skill changes without consuming the skill confirmation', async t => {
  const f = await fixture(t);
  f.store.save('rooms', f.ids.resident, { id: 'review-rollback', status: 1, revision: 0 });
  const preview = await f.call('worker', 'PUT', '/worker/skills', { workforceRevision: 0, skills: ['doors'], preview: true });
  const body = { workforceRevision: 0, skills: ['doors'], previewToken: preview.previewToken };
  f.store.db.exec("CREATE TRIGGER injected_audit_failure BEFORE INSERT ON management_audit BEGIN SELECT RAISE(ABORT,'audit unavailable'); END");
  assert.equal((await f.raw('admin', 'PUT', '/management/rooms/review-rollback/review', { revision: 0, decision: 'reject', reason: '测试' })).status, 500);
  assert.equal(f.store.get('rooms', f.ids.resident, 'review-rollback')!.status, 1);
  assert.equal((await f.raw('worker', 'PUT', '/worker/skills', body)).status, 500);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM worker_skills WHERE workerId=?', f.ids.worker)!.n, 3);
  f.store.db.exec('DROP TRIGGER injected_audit_failure');
  await f.call('worker', 'PUT', '/worker/skills', body);
  assert.equal((await f.call('admin', 'GET', '/management/audit-events')).rows.length, 1);
});

test('capacity changes record scoped values and failed audit storage restores capacity revision', async t => {
  const f = await fixture(t);
  await f.capacities(7);
  await f.configureCapacities('/management/repair-capacities/weekdays/7', { '10': 3 });
  await f.configureCapacities('/management/repair-capacities/2026-10-18', { '10': 1 });
  await f.configureCapacities('/management/repair-capacities/2026-10-18');
  await f.configureCapacities('/management/repair-capacities/weekdays/7');
  const rows = (await f.call('admin', 'GET', '/management/audit-events')).rows;
  assert.deepEqual(rows.map((row: Row) => row.targetType), ['capacity-weekday','capacity-date','capacity-date','capacity-weekday','capacity-default']);
  assert.deepEqual(rows[0].before.capacities, { '10': 3 });
  assert.deepEqual(rows[0].after.capacities, {});
  const before = await f.call('admin', 'GET', '/management/repair-capacities');
  f.store.db.exec("CREATE TRIGGER injected_audit_failure BEFORE INSERT ON management_audit BEGIN SELECT RAISE(ABORT,'audit unavailable'); END");
  assert.equal((await f.raw('admin', 'PUT', '/management/repair-capacities', { revision: before.revision, capacities: { '10': 9 } })).status, 500);
  assert.deepEqual(await f.call('admin', 'GET', '/management/repair-capacities'), before);
});

test('audit keyset paging is stable when newer events arrive and supports actor/action/target filters', async t => {
  const f = await fixture(t);
  let repair = await f.create();
  for (let i = 0; i < 5; i++) repair = await f.change('admin', repair, 'notes', { content: '记录' }, 'POST');
  const query = `/management/audit-events?limit=2&actorId=${f.ids.admin}&targetType=repair&targetId=${repair.id}&action=repair.note`;
  const first = await f.call('admin', 'GET', query);
  await f.change('admin', repair, 'notes', { content: '新记录' }, 'POST');
  const second = await f.call('admin', 'GET', query + '&before=' + first.nextCursor);
  const third = await f.call('admin', 'GET', query + '&before=' + second.nextCursor);
  const ids = [...first.rows, ...second.rows, ...third.rows].map(row => row.seq);
  assert.equal(ids.length, 5);
  assert.equal(new Set(ids).size, 5);
  assert(ids.every(id => id <= first.rows[0].seq));
  assert.equal(third.nextCursor, null);
});

test('version 11 migration preserves known legacy provenance, reopen and backup restore without duplicating events', async () => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-audit-migration-'));
  const file = join(directory, 'source.sqlite');
  let store = new Store(file);
  try {
    store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('admin','13900001111','物业','admin'),('worker','13900002222','师傅','worker')");
    store.run("INSERT INTO account_events(userId,actorId,enabled,reason,createdAt) VALUES ('worker','admin',0,'不复制私密原因',?)", START);
    store.run("INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES ('worker','worker','不复制姓名',?)", new Date(START).toISOString());
    store.db.exec('DROP TABLE management_audit; PRAGMA user_version=11');
    store.close();
    store = new Store(file);
    assert.equal(store.one('PRAGMA user_version')!.user_version, 13);
    const migrated = new ManagementAudit(store).list('admin', {}).rows;
    assert.equal(migrated.length, 2);
    assert.deepEqual(new Set(migrated.map(row => row.source)), new Set(['legacy-account', 'legacy-skill-latest']));
    assert(migrated.every(row => row.before === null));
    assert.doesNotMatch(JSON.stringify(migrated), /不复制/);
    store.close();
    store = new Store(file);
    assert.deepEqual(new ManagementAudit(store).list('admin', {}).rows, migrated);
    const backup = join(directory, 'backup'), restored = join(directory, 'restored');
    const manifest = await createBackup(file, backup);
    assert.equal(manifest.tables.management_audit!.rows, 2);
    await restoreBackup(backup, restored);
    const copy = new Store(join(restored, 'database.sqlite'));
    try {
      assert.deepEqual(new ManagementAudit(copy).list('admin', {}).rows, migrated);
      assert.throws(() => copy.run('DELETE FROM management_audit'), /append-only/);
    } finally { copy.close(); }
  } finally { store.close(); rmSync(directory, { recursive: true, force: true }); }
});
