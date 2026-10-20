import type { TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import type { PushTransport } from '../src/push-transport.js';

export const H = 3_600_000;
export const START = Date.parse('2026-10-17T08:00:00+08:00');
export const SLOT = '2026-10-18#10';
export const NEXT = '2026-10-18#11';
export type Row = Record<string, any>;
export type Role = 'resident' | 'other' | 'worker' | 'worker2' | 'admin';

export async function fixture(t: TestContext, options: { pushTransport?: PushTransport; pushTimer?: boolean } = {}) {
  let now = START;
  const config = readConfig({ DATABASE_PATH: ':memory:' });
  const { app, store, notifications } = createApp(config, { now: () => now, pushTimer: false, log: () => {}, ...options });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await notifications.stop();
    store.close();
  });
  const tokens = {} as Record<Role, string>;
  const ids = {} as Record<Role, string>;
  async function raw(role: Role | undefined, method: string, path: string, body?: unknown): Promise<Row> {
    const response = await fetch(base + path, { method, headers: {
      ...(role ? { Authorization: `Bearer ${tokens[role]}` } : {}), 'Content-Type': 'application/json',
    }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, ...await response.json() as Row };
  }
  async function call(role: Role, method: string, path: string, body?: unknown): Promise<any> {
    const result = await raw(role, method, path, body);
    assert.equal(result.code, 10000, `${method} ${path}: ${result.status} ${result.message}`);
    return result.data;
  }
  for (const [index, role] of (['resident', 'other', 'worker', 'worker2', 'admin'] as const).entries()) {
    const mobile = `1380013800${index}`;
    const code = await raw(undefined, 'GET', `/code?mobile=${mobile}`);
    const session = await raw(undefined, 'POST', '/login', { mobile, code: code.data.code });
    assert.equal(session.code, 10000);
    tokens[role] = session.data.token;
    ids[role] = String(store.one('SELECT id FROM users WHERE mobile=?', mobile)!.id);
    if (role !== 'resident' && role !== 'other') store.run('UPDATE users SET role=? WHERE id=?', role === 'worker2' ? 'worker' : role, ids[role]);
    if (role === 'worker' || role === 'worker2') {
      for (const skill of ['plumbing', 'electrical', 'doors']) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', ids[role], skill);
    }
  }
  // 此套件只验证预约时钟，保持已登录会话有效，鉴权本身由原测试覆盖。
  store.run('UPDATE sessions SET accessExpires=?', START + 90 * 24 * H);
  const houseId = randomUUID();
  store.save('rooms', ids.resident, { id: houseId, point: '测试小区', building: '1栋', room: '101' });
  const body = { houseId, mobile: '13800138000', repairItemId: '1004' };
  async function create(slot = SLOT, extra: Row = {}) {
    const result = await call('resident', 'POST', '/repair', { ...body, slot, ...extra });
    return result.rows.find((row: Row) => row.id === result.createdId) as Row;
  }
  async function change(role: Role, row: Row, action: string, body: Row = {}, method = 'PUT') {
    const prefix = role === 'admin' ? '/management/repairs' : role.startsWith('worker') ? '/worker/repairs' : '/repair';
    return call(role, method, `${prefix}/${row.id}/${action}`, { revision: row.revision, ...body });
  }
  async function processing(slot = SLOT, role: 'worker' | 'worker2' = 'worker') {
    const row = await create(slot);
    const assigned = await change('admin', row, 'assign', { workerId: ids[role] });
    return change(role, assigned, 'accept');
  }
  const detail = (row: Row) => call('resident', 'GET', `/repair/${row.id}`);
  const slots = (day = '2026-10-18', excludeId = '') => call('resident', 'GET', `/repair/slots?date=${day}${excludeId ? `&excludeId=${excludeId}` : ''}`);
  const stored = (row: Row) => store.get('repairs', ids.resident, row.id)! as Row & { id: string };
  const capacities = (capacity: number, hour = '10') => call('admin', 'PUT', '/management/repair-capacities', { capacities: { [hour]: capacity } });
  return { raw, call, change, create, processing, detail, slots, stored, capacities, body, store, ids, config, notifications,
    time: () => now, at: (time: number) => { now = time; } };
}
