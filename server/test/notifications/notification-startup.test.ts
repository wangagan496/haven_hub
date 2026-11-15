import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { Store, type RecordData } from '../../src/database.js';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';
import { Notifications } from '../../src/notifications.js';
import type { PushTransport } from '../../src/push-transport.js';

const START = Date.parse('2026-10-28T00:00:00Z');
const startupQuery = 'SELECT userId,payload FROM repairs';
const transport: PushTransport = {
  publicConfig: () => ({ webPublicKey: '', harmonyConfigured: false }),
  send: async () => { throw new Error('Startup must not send push requests'); },
};
const record = (id: string): RecordData => ({ id, status: 6, revision: 1, rounds: [{ number: 1 }], pendings: [], timeline: [] });

function seed(t: TestContext) {
  const folder = mkdtempSync(join(tmpdir(), 'haven-startup-stream-'));
  t.after(() => rmSync(folder, { recursive: true, force: true }));
  const path = join(folder, 'database.sqlite');
  const store = new Store(path);
  for (const [id, role] of [['owner', 'resident'], ['worker', 'worker'], ['admin', 'admin']]) {
    store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', id!, id!, id!, role!);
  }
  return { store, path, config: readConfig({ DATABASE_PATH: path }) };
}

test('startup rebuild streams repairs while notification transactions commit and does not rewrite payloads', t => {
  const f = seed(t);
  for (let i = 0; i < 37; i++) f.store.save('repairs', 'owner', record(`r${i}`));
  const before = f.store.db.prepare('SELECT id,payload FROM repairs ORDER BY seq').all();
  f.store.close();
  const prepare = DatabaseSync.prototype.prepare;
  const close = DatabaseSync.prototype.close;
  let connection: DatabaseSync | undefined;
  let scans = 0;
  t.mock.method(DatabaseSync.prototype, 'prepare', function (this: DatabaseSync, sql: string) {
    connection = this;
    const statement = prepare.call(this, sql);
    if (sql === startupQuery) {
      scans++;
      statement.all = () => { throw new Error('startup retained every repair payload'); };
    }
    return statement;
  });
  let app: ReturnType<typeof createApp> | undefined;
  try {
    app = createApp(f.config, { now: () => START, pushTimer: false, pushTransport: transport, log: () => {} });
    assert.equal(scans, 1);
    assert.equal(app.store.one('SELECT COUNT(*) AS count FROM notifications WHERE active=1')!.count, 37);
    assert.deepEqual(app.store.db.prepare('SELECT id,payload FROM repairs ORDER BY seq').all(), before);
    app.store.transaction(() => app!.store.run("UPDATE users SET nickName='after-startup' WHERE id='owner'"));
    assert.equal(app.store.one("SELECT nickName FROM users WHERE id='owner'")!.nickName, 'after-startup');
  } finally {
    if (app) app.store.close();
    else connection && close.call(connection);
  }
});

test('startup read cursor survives a notification savepoint rollback and retries the missing task on restart', t => {
  const f = seed(t);
  for (const id of ['first', 'fail-once', 'last']) f.store.save('repairs', 'owner', record(id));
  f.store.db.exec(`CREATE TRIGGER fail_one_notification BEFORE INSERT ON notifications
    WHEN NEW.repairId='fail-once' BEGIN SELECT RAISE(ABORT, 'injected notification failure'); END;`);
  f.store.close();
  const logs: { event?: string; repairId?: string }[] = [];
  let app = createApp(f.config, { now: () => START, pushTimer: false, pushTransport: transport, log: event => logs.push(event) });
  try {
    assert.deepEqual(app.store.db.prepare('SELECT repairId FROM notifications ORDER BY repairId').all().map(row => row.repairId), ['first', 'last']);
    assert(logs.some(event => event.event === 'notification_sync_failed' && event.repairId === 'fail-once'));
    app.store.db.exec('DROP TRIGGER fail_one_notification');
    const first = app.store.one("SELECT id FROM notifications WHERE repairId='first'")!;
    app.notifications.read('owner', String(first.id));
  } finally { app.store.close(); }
  app = createApp(f.config, { now: () => START + 1000, pushTimer: false, pushTransport: transport, log: () => {} });
  try {
    assert.equal(app.store.one('SELECT COUNT(*) AS count FROM notifications')!.count, 3);
    assert.equal(app.store.one("SELECT readAt FROM notifications WHERE repairId='first'")!.readAt, START);
    assert.equal(app.store.one("SELECT createdAt FROM notifications WHERE repairId='fail-once'")!.createdAt, START + 1000);
  } finally { app.store.close(); }
});

test('startup settles deadlines, closes old deliveries, isolates corrupt data and preserves delivery retries across restarts', t => {
  const f = seed(t);
  const notifications = new Notifications(f.store, transport, () => START);
  notifications.register('owner', { platform: 'harmony', token: 'synthetic-token', installationId: 'a'.repeat(64) });
  const completed = record('expired-confirm');
  f.store.save('repairs', 'owner', completed);
  notifications.sync('owner', completed);
  f.store.save('repairs', 'owner', { ...completed, rounds: [{ number: 1, confirmDeadline: new Date(START).toISOString() }] }, true);
  f.store.run('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)', 'bad', 'owner', 'null');
  const waiting = record('waiting');
  f.store.save('repairs', 'owner', waiting);
  notifications.sync('owner', waiting);
  const note = f.store.one("SELECT id FROM notifications WHERE repairId='waiting'")!;
  f.store.run("UPDATE push_deliveries SET status='failed',attempts=3,nextAt=? WHERE notificationId=?", START + 60000, String(note.id));
  const before = f.store.db.prepare('SELECT * FROM push_deliveries WHERE notificationId=?').all(String(note.id));
  f.store.close();
  for (let pass = 0; pass < 2; pass++) {
    const logs: { event?: string }[] = [];
    const app = createApp(f.config, { now: () => START, pushTimer: false, pushTransport: transport, log: event => logs.push(event) });
    try {
      assert.equal(app.store.get('repairs', 'owner', 'expired-confirm')!.status, 3);
      assert.equal(app.store.one("SELECT active FROM notifications WHERE repairId='expired-confirm'")!.active, 0);
      assert.equal(app.store.one("SELECT status FROM push_deliveries WHERE notificationId=(SELECT id FROM notifications WHERE repairId='expired-confirm')")!.status, 'cancelled');
      assert.equal(app.store.one('SELECT COUNT(*) AS count FROM notifications')!.count, 2);
      assert.deepEqual(app.store.db.prepare('SELECT * FROM push_deliveries WHERE notificationId=?').all(String(note.id)), before);
      assert(logs.some(event => event.event === 'notification_startup_sync_failed'));
    } finally { app.store.close(); }
  }
});

for (const failure of ['prepare', 'cursor'] as const) {
  test(`startup ${failure} failure propagates and closes the database before any timer is created`, t => {
    const f = seed(t);
    f.store.save('repairs', 'owner', record('first'));
    f.store.close();
    const prepare = DatabaseSync.prototype.prepare;
    const close = DatabaseSync.prototype.close;
    let connection: DatabaseSync | undefined;
    let closes = 0;
    let cursorClosed = false;
    t.mock.method(DatabaseSync.prototype, 'close', function (this: DatabaseSync) { closes++; return close.call(this); });
    t.mock.method(DatabaseSync.prototype, 'prepare', function (this: DatabaseSync, sql: string) {
      connection = this;
      if (sql === startupQuery && failure === 'prepare') throw new Error('injected startup read failure');
      const statement = prepare.call(this, sql);
      if (sql === startupQuery && failure === 'cursor') statement.iterate = function* () {
        try { yield { userId: 'owner', payload: JSON.stringify(record('first')) }; throw new Error('injected startup read failure'); }
        finally { cursorClosed = true; }
      };
      return statement;
    });
    let timers = 0;
    t.mock.method(globalThis, 'setInterval', () => { timers++; throw new Error('unexpected startup timer'); });
    try {
      assert.throws(() => createApp(f.config, { now: () => START, pushTransport: transport, log: () => {} }), /injected startup read failure/);
      assert.equal(closes, 1);
      assert.equal(timers, 0);
      if (failure === 'cursor') assert(cursorClosed);
    } finally {
      if (connection && closes === 0) close.call(connection);
    }
  });
}
