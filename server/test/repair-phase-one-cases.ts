import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import type { ApiFixtureFactory } from './api.test.js';

// Reuses the existing HTTP fixture; every case owns an isolated in-memory DB.
const H = 3_600_000;
const R = '13800138000', A = '13800138090', W = '13800138091';
type Role = 'resident' | 'admin' | 'worker';
type Row = Record<string, any>;
const iso = (ms: number) => new Date(ms).toISOString();
const local = (ms: number) => iso(ms).slice(0, 19) + '+00:00';

export function registerPhaseOneTests(fixture: ApiFixtureFactory) {
  async function setup(t: TestContext) {
    let now = Date.parse('2026-10-17T00:00:00Z');
    const f = await fixture(t, ':memory:', () => now);
    const tokens: Record<Role, string> = { resident: '', admin: '', worker: '' };
    const mobiles: Record<Role, string> = { resident: R, admin: A, worker: W };
    for (const role of ['resident', 'admin', 'worker'] as const) {
      tokens[role] = (await f.login(mobiles[role])).token;
      if (role !== 'resident') f.store.run('UPDATE users SET role = ? WHERE mobile = ?', role, mobiles[role]);
    }
    const workerId = String(f.store.one('SELECT id FROM users WHERE mobile = ?', W)!.id);
    const house = await f.room(tokens.resident);
    async function raw(role: Role, method: string, path: string, body?: unknown) {
      return f.request(method, path, tokens[role], body);
    }
    async function call(role: Role, method: string, path: string, body?: unknown): Promise<any> {
      const response = await raw(role, method, path, body);
      assert.equal(response.code, 10000, `${method} ${path}: ${response.status} ${response.message}`);
      return response.data;
    }
    const detail = (id: string) => call('resident', 'GET', `/repair/${id}`);
    async function change(role: Role, row: Row, action: string, body: Row = {}, method = 'PUT') {
      const prefix = role === 'resident' ? '/repair' : role === 'worker' ? '/worker/repairs' : '/management/repairs';
      return call(role, method, `${prefix}/${row.id}/${action}`, { revision: row.revision, ...body });
    }
    async function create(stage: 1 | 5 | 2 | 6 | 3 = 2, hours = 24): Promise<Row> {
      const created = await call('resident', 'POST', '/repair', { houseId: house.record.id,
        repairItemId: '1001', mobile: R, expectedTime: local(now + hours * H) });
      assert(created.createdId);
      let row = await detail(created.createdId);
      if (stage === 1) return row;
      row = await change('admin', row, 'assign', { workerId });
      if (stage === 5) return row;
      row = await change('worker', row, 'accept');
      if (stage === 2) return row;
      row = await change('worker', row, 'complete', { result: '第一轮换水管', cost: 12.5 });
      assert.equal(row.status, 6);
      if (stage === 6) return row;
      return change('resident', row, 'confirm');
    }
    async function at(time: number, roles: Role[] = ['resident', 'admin', 'worker']) {
      assert(time >= now, 'test clock only moves forward');
      const jump = time - now;
      now = time;
      // Large jumps need fresh tokens. Short boundary steps reuse fresh tokens,
      // preserving exact milliseconds and staying below per-app auth limits.
      if (jump >= 30 * 60_000) {
        for (const role of roles) tokens[role] = (await f.login(mobiles[role])).token;
      }
    }
    function stored(id: string): Row {
      return JSON.parse(String(f.store.one('SELECT payload FROM repairs WHERE id = ?', id)!.payload));
    }
    function seed(row: Row) {
      // Only migration/unreachable defense fixtures use direct writes, never production data.
      f.store.run('UPDATE repairs SET payload = ? WHERE id = ?', JSON.stringify(row), row.id);
    }
    async function denied(role: Role, row: Row, action: string, body: Row = {}, method = 'PUT', status = 200) {
      const prefix = role === 'resident' ? '/repair' : role === 'worker' ? '/worker/repairs' : '/management/repairs';
      const response = await raw(role, method, `${prefix}/${row.id}/${action}`, { revision: row.revision, ...body });
      assert.equal(response.status, status, response.message);
      if (status === 200) assert([40000, 40001].includes(response.code), `expected validation/business rejection: ${response.code}`);
      else assert.equal(response.code, status === 409 ? 40900 : 40400);
      return response;
    }
    return { ...f, tokens, raw, call, change, detail, create, at, stored, seed, denied, workerId, now: () => now };
  }

  for (const explicitTime of [false, true]) {
    test(`FIX-A valid expected time explicit=${explicitTime} needs no reason or proposal`, async t => {
      const f = await setup(t);
      const row = await f.create(5);
      const accepted = await f.change('worker', row, 'accept', explicitTime ? { time: row.expectedTime } : {});
      assert.equal(accepted.status, 2);
      assert.equal(accepted.revision, row.revision + 1);
      assert.equal(accepted.agreedTime, row.expectedTime);
      assert.equal(accepted.pendings.length, 0);
      assert(!accepted.timeline.some((e: Row) => e.action === 'reschedule_proposed'));
    });
  }

  for (const action of ['confirm', 'reject']) {
    test(`FIX-B stale resident ${action} after confirmation returns 409`, async t => {
      const f = await setup(t);
      const row = await f.create(6);
      const done = await f.change('resident', row, 'confirm');
      await f.denied('resident', row, action, action === 'reject' ? { reason: '仍未修好' } : {}, 'PUT', 409);
      const latest = await f.detail(row.id);
      assert.equal(latest.revision, done.revision);
      assert.equal(latest.status, 3);
      assert.equal(latest.round, 1);
    });
  }

  test('FIX-B stale foreign resident and unassigned worker stay 404 across all guarded actions', async t => {
    const f = await setup(t);
    const row = await f.create(3);
    const other = await f.login('13800138001');
    const stale = row.revision - 1;
    const future = local(f.now() + H);
    const requests: Array<[string, string, Row]> = [
      ['PUT', 'confirm', {}], ['PUT', 'reject', { reason: '未修好' }],
      ['POST', 'aftersale', { reason: '售后' }], ['POST', 'feedback', { content: '反馈' }],
      ['PUT', 'revoke', { reason: '撤销', notified: true }],
      ['POST', 'reschedule', { time: future, reason: '改约', notified: true }],
      ['PUT', 'reschedule', { accept: true }],
    ];
    for (const [method, action, body] of requests) {
      const result = await f.request(method, `/repair/${row.id}/${action}`, other.token, { revision: stale, ...body });
      assert.deepEqual([result.status, result.code], [404, 40400], action);
    }
    f.store.run("UPDATE users SET role = 'worker' WHERE mobile = ?", '13800138001');
    const workerRequests: Array<[string, string, Row]> = [
      ['PUT', 'accept', {}], ['PUT', 'complete', { result: '已修好' }],
      ['PUT', 'release', { reason: '退出' }], ['POST', 'progress', { content: '进展' }],
      ['PUT', 'revoke', {}], ['POST', 'objection', { reason: '异议' }],
      ['POST', 'reschedule', { time: future, reason: '改约', notified: true }],
      ['PUT', 'reschedule', { accept: true }],
    ];
    for (const [method, action, body] of workerRequests) {
      const result = await f.request(method, `/worker/repairs/${row.id}/${action}`, other.token, { revision: stale, ...body });
      assert.deepEqual([result.status, result.code], [404, 40400], action);
    }
    assert.equal(f.stored(row.id).revision, row.revision);
  });

  test('FIX-B stale property assignment returns 409 but all management routes retain role guards', async t => {
    const f = await setup(t);
    const assigned = await f.create(5);
    const accepted = await f.change('worker', assigned, 'accept');
    await f.denied('admin', assigned, 'assign', { workerId: f.workerId }, 'PUT', 409);
    const currentError = await f.raw('admin', 'PUT', `/management/repairs/${accepted.id}/assign`,
      { revision: accepted.revision, workerId: f.workerId });
    assert.deepEqual([currentError.status, currentError.code], [200, 40001]);
    for (const role of ['resident', 'worker'] as const) {
      for (const [method, action, body] of [
        ['PUT', 'assign', { workerId: f.workerId }], ['PUT', 'aftersale', { approve: true }],
        ['PUT', 'reschedule', { accept: true }], ['POST', 'notes', { content: '越权跟进', target: 'follow' }],
      ] as const) {
        const response = await f.raw(role, method, `/management/repairs/${accepted.id}/${action}`,
          { revision: assigned.revision, ...body });
        assert.equal(response.status, 403, `${role} ${action}`);
      }
    }
    assert.equal(f.stored(accepted.id).revision, accepted.revision);
  });

  test('FIX-B current revision preserves business errors and leaves completed work untouched', async t => {
    const f = await setup(t);
    const row = await f.create(3);
    for (const [role, action, body, method] of [
      ['resident', 'confirm', {}, 'PUT'], ['resident', 'reject', { reason: '未修好' }, 'PUT'],
      ['worker', 'accept', {}, 'PUT'], ['worker', 'complete', { result: '重复完工' }, 'PUT'],
      ['worker', 'release', { reason: '退出' }, 'PUT'], ['worker', 'progress', { content: '进展' }, 'POST'],
    ] as const) {
      const prefix = role === 'resident' ? '/repair' : '/worker/repairs';
      const response = await f.raw(role, method, `${prefix}/${row.id}/${action}`, { revision: row.revision, ...body });
      assert.deepEqual([response.status, response.code], [200, 40001], action);
    }
    assert.deepEqual(f.stored(row.id).timeline, row.timeline);
    assert.equal(f.stored(row.id).revision, row.revision);
  });

  test('FIX-B schema and pre-mutation input validation precede stale revision checks', async t => {
    const f = await setup(t);
    const row = await f.create(3);
    const malformed = await f.raw('resident', 'PUT', `/repair/${row.id}/confirm`,
      { revision: row.revision - 1, unexpected: true });
    assert.deepEqual([malformed.status, malformed.code], [200, 40000]);
    const blank = await f.raw('worker', 'PUT', `/worker/repairs/${row.id}/complete`,
      { revision: row.revision - 1, result: '' });
    assert.deepEqual([blank.status, blank.code], [200, 40001]);
    assert.equal(f.stored(row.id).revision, row.revision);
  });

  test('P1-01 resident confirmation starts 720-hour warranty at confirmation', async t => {
    const f = await setup(t);
    const row = await f.create(6);
    assert.equal(row.rounds[0].confirmedBy, '');
    await f.at(f.now() + H);
    const done = await f.change('resident', row, 'confirm');
    assert.equal(done.status, 3);
    assert.equal(done.rounds[0].confirmedBy, 'resident');
    assert.equal(done.rounds[0].confirmedAt, iso(f.now()));
    assert.equal(done.warrantyEnd, iso(f.now() + 720 * H));
    await f.denied('resident', done, 'confirm');
  });

  for (const entry of ['resident-list', 'resident-detail', 'worker-list', 'worker-detail', 'management-list', 'write']) {
    test(`P1-01/02 exact 72-hour auto confirmation via ${entry}`, async t => {
      const f = await setup(t);
      const row = await f.create(6);
      const deadline = Date.parse(row.confirmDeadline);
      await f.at(deadline - 1);
      assert.equal((await f.detail(row.id)).status, 6);
      await f.at(deadline);
      if (entry === 'resident-list') {
        const page = await f.call('resident', 'GET', '/repair?current=1&pageSize=1');
        assert.equal(page.total, 1);
        assert.equal(page.rows[0].status, 3);
      } else if (entry === 'resident-detail') assert.equal((await f.detail(row.id)).status, 3);
      else if (entry === 'worker-list') assert.equal((await f.call('worker', 'GET', '/worker/repairs'))[0].status, 3);
      else if (entry === 'worker-detail') assert.equal((await f.call('worker', 'GET', `/worker/repairs/${row.id}`)).status, 3);
      else if (entry === 'management-list') assert.equal((await f.call('admin', 'GET', '/management/repairs'))[0].status, 3);
      else await f.denied('resident', row, 'feedback', { content: '旧版本反馈' }, 'POST', 409);
      // Inspect persistence before another GET can mask a rolled-back settlement.
      const persisted = f.stored(row.id);
      assert.equal(persisted.status, 3);
      assert.equal(persisted.revision, row.revision + 1);
      assert.equal(persisted.rounds[0].confirmedBy, 'system');
      assert.equal(persisted.rounds[0].confirmedAt, iso(deadline));
      assert.equal(persisted.timeline.filter((e: Row) => e.action === 'auto_confirmed').length, 1);
      assert.equal(persisted.pendings.filter((p: Row) => p.kind === 'feedback').length, 0);
      if (entry === 'write') {
        const updated = await f.change('resident', persisted, 'feedback', { content: '刷新后主动反馈' }, 'POST');
        assert.equal(updated.status, 3);
      }
    });
  }

  test('P1-03/10 two rounds preserve histories; no third round; verification does not overwrite cost', async t => {
    const f = await setup(t);
    let row = await f.create(6);
    const first = structuredClone(row.rounds[0]);
    row = await f.change('resident', row, 'reject', { reason: '仍然漏水' });
    assert.equal(row.status, 2);
    assert.equal(row.workerId, f.workerId);
    assert.equal(row.agreedTime, '');
    assert.equal(row.round, 2);
    assert.equal(row.reworkUsed, true);
    assert.equal(row.rounds[0].note, first.note);
    assert.equal(row.rounds[0].cost, first.cost);
    assert.equal(row.rounds[0].rejectReason, '仍然漏水');
    assert.equal(row.rounds[0].confirmDeadline, '');
    await f.denied('admin', row, 'notes', { target: 'verify', content: '尚未完工', round: 2 }, 'POST');
    row = await f.change('admin', row, 'notes', { target: 'verify', content: '首轮已核实', cost: 10, round: 1 }, 'POST');
    assert.equal(row.rounds[0].cost, 12.5);
    assert.match(row.rounds[0].verifiedNote, /首轮已核实.*10/);
    row = await f.change('worker', row, 'complete', { result: '第二轮更换阀门', cost: 20 });
    await f.denied('resident', row, 'reject', { reason: '申请第三轮' });
    row = await f.change('resident', row, 'confirm');
    assert.equal(row.warrantyEnd, iso(f.now() + 480 * H));
    assert.equal(row.rounds[1].confirmedBy, 'resident');
    assert.equal(row.rounds[1].note, '第二轮更换阀门');
    assert.equal(row.rounds[1].cost, 20);
    assert.equal(row.rounds[0].note, first.note);
    await f.denied('resident', row, 'aftersale', { reason: '第三轮' }, 'POST');
    // Defensive legacy/corrupt pending: prove review's round limit, not just no-pending guard.
    const injected = f.stored(row.id);
    injected.pendings.push({ id: 'legacy-pending', kind: 'aftersale', by: 'resident', at: iso(f.now()), reason: '旧申请' });
    f.seed(injected);
    await f.denied('admin', row, 'aftersale', { approve: true });
    row = await f.change('resident', row, 'feedback', { content: '请物业跟进' }, 'POST');
    assert.equal(row.status, 3);
    assert.equal(row.rounds.length, 2);
    await f.denied('resident', row, 'feedback', { content: '重复反馈' }, 'POST');
    assert((await f.call('admin', 'GET', '/management/repairs'))[0].todo.includes('问题反馈待回复'));
    row = await f.change('admin', row, 'notes', { target: 'feedback', content: '已联系双方' }, 'POST');
    assert(!row.todo.includes('问题反馈待回复'));
    assert.equal(row.status, 3);
  });

  test('P1-04 aftersale only after completion; duplicate/reject rules and review after expiry', async t => {
    const f = await setup(t);
    let row = await f.create(6);
    await f.denied('resident', row, 'aftersale', { reason: '还没确认' }, 'POST');
    row = await f.change('resident', row, 'confirm');
    const end = Date.parse(row.warrantyEnd);
    row = await f.change('resident', row, 'aftersale', { reason: '又漏水' }, 'POST');
    await f.denied('resident', row, 'aftersale', { reason: '重复' }, 'POST');
    await f.denied('admin', row, 'aftersale', { approve: false });
    row = await f.change('admin', row, 'aftersale', { approve: false, reason: '请补充现象' });
    assert.equal(row.reworkUsed, false);
    assert.equal(row.rounds.length, 1);
    await f.at(end - 1);
    row = await f.change('resident', row, 'aftersale', { reason: '期限前补充' }, 'POST');
    assert.equal(row.status, 3);
    await f.at(end + 1);
    assert.equal((await f.detail(row.id)).closed, false);
    row = await f.change('admin', row, 'aftersale', { approve: true });
    assert.equal(row.status, 2);
    assert.equal(row.round, 2);
    assert.equal(row.workerId, f.workerId);
    assert.equal(row.agreedTime, '');
  });

  test('P1-03/09/10 approved aftersale retains first confirmation and second auto confirmation uses 480h', async t => {
    const f = await setup(t);
    let row = await f.create(3);
    const first = structuredClone(row.rounds[0]);
    assert.equal(row.workerMobile, W);
    assert.equal(row.propertyPhone, f.config.propertyPhone);
    row = await f.change('resident', row, 'aftersale', { reason: '漏水复发' }, 'POST');
    row = await f.change('admin', row, 'aftersale', { approve: true });
    row = await f.change('worker', row, 'complete', { result: '第二次维修', cost: 25 });
    assert.equal(row.mobile, R);
    const deadline = Date.parse(row.confirmDeadline);
    await f.at(deadline + 1);
    row = await f.detail(row.id);
    assert.deepEqual(row.rounds[0], first);
    assert.equal(row.rounds[1].note, '第二次维修');
    assert.equal(row.rounds[1].cost, 25);
    assert.equal(row.rounds[1].confirmedBy, 'system');
    assert.equal(row.rounds[1].confirmedAt, iso(deadline));
    assert.equal(row.warrantyEnd, iso(deadline + 480 * H));
    row = await f.change('admin', row, 'notes', { target: 'verify', content: '第二轮已核实', cost: 20 }, 'POST');
    assert.equal(row.rounds[1].cost, 25);
    assert.match(row.rounds[1].verifiedNote, /第二轮已核实.*20/);
    assert.deepEqual(row.rounds[0], first);
  });

  test('P1-08 assigned worker can release before acceptance without creating another round', async t => {
    const f = await setup(t);
    let row = await f.create(5);
    const released = await f.change('worker', row, 'release', { reason: '无法接单' });
    assert.equal(released.released, row.id);
    row = await f.detail(row.id);
    assert.equal(row.status, 1);
    assert.equal(row.round, 1);
    assert.equal(row.agreedTime, '');
    assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
  });

  for (const round of [1, 2]) {
    test(`P1-04/09 round ${round} warranty cutoff and role-specific phone views`, async t => {
      const f = await setup(t);
      let row = await f.create(6);
      if (round === 2) {
        row = await f.change('resident', row, 'reject', { reason: '未修好' });
        row = await f.change('worker', row, 'complete', { result: '返修完成', cost: 0 });
      }
      row = await f.change('resident', row, 'confirm');
      const end = Date.parse(row.warrantyEnd);
      assert.equal(end - f.now(), (round === 1 ? 720 : 480) * H);
      for (const delta of [-1, 0]) {
        await f.at(end + delta);
        const resident = await f.detail(row.id);
        const worker = await f.call('worker', 'GET', `/worker/repairs/${row.id}`);
        const residentList = await f.call('resident', 'GET', '/repair');
        const workerList = await f.call('worker', 'GET', '/worker/repairs');
        const admin = (await f.call('admin', 'GET', '/management/repairs'))[0];
        assert.equal(resident.closed, delta === 0);
        for (const view of [resident, residentList.rows[0]]) assert.equal(view.workerMobile, delta < 0 ? W : '138****8091');
        for (const view of [worker, workerList[0]]) assert.equal(view.mobile, delta < 0 ? R : '138****8000');
        for (const view of [resident, worker, residentList.rows[0], workerList[0], admin]) assert.equal(view.propertyPhone, f.config.propertyPhone);
        assert.equal(admin.mobile, R);
        assert.equal(admin.workerMobile, W);
      }
      await f.denied('resident', row, 'aftersale', { reason: '到期申请' }, 'POST');
      await f.denied('resident', row, 'feedback', { content: '到期反馈' }, 'POST');
    });
  }

  test('P1-05 reschedule requires notice, cannot self-answer, never auto-accepts; property can answer', async t => {
    const f = await setup(t);
    let row = await f.create();
    const agreed = row.agreedTime;
    const time = local(f.now() + 100 * H);
    await f.denied('resident', row, 'reschedule', { time, reason: '时间冲突' }, 'POST');
    row = await f.change('resident', row, 'reschedule', { time, reason: '时间冲突', notified: true }, 'POST');
    assert.equal(row.agreedTime, agreed);
    await f.denied('resident', row, 'reschedule', { accept: true });
    await f.denied('worker', row, 'reschedule', { accept: false });
    await f.at(f.now() + 48 * H);
    row = await f.detail(row.id);
    assert.equal(row.agreedTime, agreed);
    assert.equal(row.pendings[0].resolvedAt, undefined);
    row = await f.change('worker', row, 'reschedule', { accept: false, reason: '该时间不方便' });
    assert.equal(row.agreedTime, agreed);
    row = await f.change('worker', row, 'reschedule', { time, reason: '再协商', notified: true }, 'POST');
    await f.denied('worker', row, 'reschedule', { accept: true });
    row = await f.change('resident', row, 'reschedule', { accept: true });
    assert.equal(row.agreedTime, time);
    const next = local(f.now() + 120 * H);
    row = await f.change('resident', row, 'reschedule', { time: next, reason: '再次改约', notified: true }, 'POST');
    row = await f.change('admin', row, 'reschedule', { accept: true, reason: '已电话核实' });
    assert.equal(row.agreedTime, next);
    assert.equal(row.round, 1);
  });

  test('P1-06 acceptance adopts expected time; alternatives require reason and consent', async t => {
    const f = await setup(t);
    const direct = await f.create();
    assert.equal(direct.agreedTime, direct.expectedTime);
    let row = await f.create(5);
    const time = local(f.now() + 48 * H);
    await f.denied('worker', row, 'accept', { time });
    row = await f.change('worker', row, 'accept', { time, reason: '已有安排' });
    assert.equal(row.agreedTime, row.expectedTime);
    assert.equal(row.pendings[0].proposedTime, time);
    row = await f.change('resident', row, 'reschedule', { accept: true });
    assert.equal(row.agreedTime, time);
  });

  test('P1-06 expired expected time requires a new future time', async t => {
    const f = await setup(t);
    let row = await f.create(5, 1);
    await f.at(f.now() + 2 * H);
    await f.denied('worker', row, 'accept');
    row = await f.change('worker', row, 'accept', { time: local(f.now() + H), reason: '重新预约' });
    assert.equal(row.agreedTime, '');
    assert.equal(row.pendings[0].kind, 'reschedule');
  });

  test('P1-06 regression: repeating the expired expected time is not a new appointment', async t => {
    const f = await setup(t);
    const row = await f.create(5, 1);
    await f.at(f.now() + 2 * H);
    const response = await f.raw('worker', 'PUT', `/worker/repairs/${row.id}/accept`,
      { revision: row.revision, time: row.expectedTime, reason: '重复过期时间' });
    const persisted = f.stored(row.id);
    assert.deepEqual({ code: response.code, status: persisted.status, agreedTime: persisted.agreedTime,
      revision: persisted.revision, pendings: persisted.pendings.length },
    { code: 40001, status: 5, agreedTime: '', revision: row.revision, pendings: 0 },
    'Expired expectedTime must be rejected without accepting the work order');
  });

  test('P1-07 direct revoke states 1/5 and legacy empty-body complete list', async t => {
    const f = await setup(t);
    for (const stage of [1, 5] as const) {
      const row = await f.create(stage);
      const revoked = await f.change('resident', row, 'revoke', { reason: '不再需要' });
      assert.equal(revoked.status, 0);
      assert.equal(revoked.closed, true);
    }
    const legacy = await f.create(5);
    const result = await f.call('resident', 'PUT', `/cancel/repair/${legacy.id}`);
    assert.equal(result.complete, true);
    assert.equal(result.total, 3);
    assert.equal(result.rows.length, 3);
    assert.equal(result.rows.find((r: Row) => r.id === legacy.id).status, 0);
  });

  for (const hours of [1, 24]) {
    test(`P1-07 revoke deadline min(2h, appointment ${hours}h), auto and objection lifecycle`, async t => {
      const f = await setup(t);
      let row = await f.create(2, hours);
      await f.denied('resident', row, 'revoke', { reason: '需要撤销' });
      row = await f.change('resident', row, 'revoke', { reason: '需要撤销', notified: true });
      const deadline = f.now() + Math.min(2, hours) * H;
      assert.equal(row.pendings[0].deadline, iso(deadline));
      await f.denied('worker', row, 'complete', { result: '撤销处理中禁止完工' });
      await f.at(deadline - 1);
      assert.equal((await f.detail(row.id)).status, 2);
      await f.at(deadline);
      row = await f.detail(row.id);
      assert.equal(row.status, 0);
      assert.equal(row.pendings[0].resolvedBy, 'system');
      assert.equal(row.objectionDeadline, iso(deadline + 72 * H));
      await f.at(deadline + 72 * H - 1);
      row = await f.change('worker', row, 'objection', { reason: '已产生材料费用' }, 'POST');
      assert.equal(row.status, 0);
      assert((await f.call('admin', 'GET', '/management/repairs'))[0].todo.includes('撤销有异议'));
      row = await f.change('admin', row, 'notes', { target: 'objection', content: '已协调' }, 'POST');
      assert(!row.todo.includes('撤销有异议'));
    });
  }

  test('P1-07 acknowledgement immediately revokes; objection at 72h rejected; write phones masked', async t => {
    const f = await setup(t);
    let row = await f.create();
    row = await f.change('resident', row, 'revoke', { reason: '撤销', notified: true });
    row = await f.change('worker', row, 'revoke');
    assert.equal(row.status, 0);
    assert.equal(row.mobile, '138****8000');
    assert.equal(row.workerMobile, '138****8091');
    assert.equal(row.propertyPhone, f.config.propertyPhone);
    assert.equal(row.pendings[0].resolvedBy, 'worker');
    await f.at(Date.parse(row.objectionDeadline));
    await f.denied('worker', row, 'objection', { reason: '已过期' }, 'POST');
  });

  for (const round of [1, 2]) {
    test(`P1-08 round ${round} release removes access, creates todo, reassignment preserves round`, async t => {
      const f = await setup(t);
      let row = await f.create(round === 1 ? 2 : 6);
      if (round === 2) row = await f.change('resident', row, 'reject', { reason: '返修' });
      const response = await f.change('worker', row, 'release', { reason: '临时有事' });
      assert.equal(response.released, row.id);
      assert(!response.rows.some((r: Row) => r.id === row.id));
      assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
      assert.equal((await f.call('worker', 'GET', '/worker/repairs')).length, 0);
      await f.denied('worker', row, 'progress', { content: '无权访问' }, 'POST', 404);
      row = await f.detail(row.id);
      assert.equal(row.status, 1);
      assert.equal(row.agreedTime, '');
      assert.equal(row.round, round);
      assert.equal(row.previousWorkers[0].reason, '临时有事');
      assert((await f.call('admin', 'GET', '/management/repairs'))[0].todo.includes('师傅退出待重派'));
      const other = await f.login('13800138092');
      f.store.run("UPDATE users SET role = 'worker' WHERE mobile = ?", '13800138092');
      const otherId = f.store.one('SELECT id FROM users WHERE mobile = ?', '13800138092')!.id;
      row = await f.change('admin', row, 'assign', { workerId: otherId });
      assert.equal(row.round, round);
      assert(!row.todo.includes('师傅退出待重派'));
      assert.equal((await f.raw('worker', 'GET', `/worker/repairs/${row.id}`)).status, 404);
      const next = await f.request('GET', `/worker/repairs/${row.id}`, other.token);
      assert.equal(next.code, 10000);
      assert.equal(next.data.previousWorkers, undefined);
    });
  }

  test('P1-11 all resident writes and worker writes enforce ownership; resident cannot manage', async t => {
    const f = await setup(t);
    const row = await f.create();
    const other = await f.login('13800138001');
    for (const [method, action, body] of [
      ['PUT', 'confirm', {}], ['PUT', 'reject', { reason: '越权' }],
      ['POST', 'aftersale', { reason: '越权' }], ['POST', 'feedback', { content: '越权' }],
      ['PUT', 'revoke', { reason: '越权', notified: true }],
      ['POST', 'reschedule', { time: local(f.now() + H), reason: '越权', notified: true }],
      ['PUT', 'reschedule', { accept: true }],
    ] as const) assert.equal((await f.request(method, `/repair/${row.id}/${action}`, other.token, { revision: row.revision, ...body })).status, 404);
    f.store.run("UPDATE users SET role = 'worker' WHERE mobile = ?", '13800138001');
    for (const [method, action, body] of [
      ['PUT', 'accept', {}], ['PUT', 'complete', { result: '越权' }], ['PUT', 'release', { reason: '越权' }],
      ['POST', 'progress', { content: '越权' }], ['PUT', 'revoke', {}],
      ['POST', 'objection', { reason: '越权' }], ['PUT', 'reschedule', { accept: true }],
      ['POST', 'reschedule', { time: local(f.now() + H), reason: '越权', notified: true }],
    ] as const) assert.equal((await f.request(method, `/worker/repairs/${row.id}/${action}`, other.token, { revision: row.revision, ...body })).status, 404);
    assert.equal((await f.raw('resident', 'GET', '/management/repairs')).status, 403);
    assert.equal((await f.raw('resident', 'PUT', `/management/repairs/${row.id}/assign`, { revision: row.revision, workerId: f.workerId })).status, 403);
    assert.equal(f.stored(row.id).revision, row.revision);
  });

  test('P1-12 legacy completed rows without rounds normalize and support aftersale/verification', async t => {
    const f = await setup(t);
    let row = await f.create(3);
    const legacy = f.stored(row.id);
    delete legacy.rounds;
    f.seed(legacy);
    row = await f.detail(row.id);
    assert.equal(row.rounds.length, 1);
    assert.equal(row.rounds[0].note, legacy.completionNote);
    assert.equal(row.rounds[0].confirmedBy, 'system');
    assert.equal(row.warrantyEnd, iso(Date.parse(legacy.completedAt) + 720 * H));
    row = await f.change('admin', row, 'notes', { target: 'verify', content: '旧单核实' }, 'POST');
    row = await f.change('resident', row, 'aftersale', { reason: '旧单售后' }, 'POST');
    row = await f.change('admin', row, 'aftersale', { approve: true });
    assert.equal(row.round, 2);
    assert.equal(row.workerId, f.workerId);
  });
}
