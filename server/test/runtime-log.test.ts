import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import fs, { existsSync, linkSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, truncateSync, writeFileSync } from 'node:fs';
import { fork, spawn, type ChildProcess } from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { createServer } from 'node:http';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { Store } from '../src/database.js';
import { RepairService } from '../src/repair/service.js';
import { RuntimeLog, projectRuntimeEvent, type RuntimeLogSettings } from '../src/runtime-log.js';

function fixture(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), "haven-runtime-logs-中文 & 引号' $()-"));
  const cleanup: Array<() => unknown | Promise<unknown>> = [];
  t.after(async () => {
    for (const close of cleanup.reverse()) await close();
    assert.equal(dirname(root), tmpdir());
    assert(basename(root).startsWith('haven-runtime-logs-'));
    rmSync(root, { recursive: true, force: true });
  });
  const settings: RuntimeLogSettings = { directory: join(root, 'logs'), maxBytes: 1024, maxFiles: 3 };
  return { root, settings, cleanup, open: (identity = 'fixture') => {
    const log = new RuntimeLog(settings, identity, () => {});
    cleanup.push(() => log.close());
    return log;
  } };
}

function segments(directory: string) { return readdirSync(directory).filter(name => name.endsWith('.jsonl')).sort(); }
function records(directory: string): Array<Record<string, unknown>> {
  return segments(directory).flatMap(name => readFileSync(join(directory, name), 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)));
}
function contents(directory: string) {
  return readdirSync(directory).sort().map(name => [name, readFileSync(join(directory, name)).toString('base64')]);
}
const access = (requestId = randomUUID()) => ({ requestId, method: 'GET', status: 200, durationMs: 2 });

async function httpApp(f: ReturnType<typeof fixture>) {
  const observed: object[] = [];
  const instance = createApp(readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: f.settings.directory }),
    { pushTimer: false, log: event => observed.push(event) });
  const server = instance.app.listen(0, '127.0.0.1');
  f.cleanup.push(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await instance.notifications.stop();
    instance.store.close();
  });
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return { ...instance, observed, base: `http://127.0.0.1:${address.port}` };
}

function exitOf(child: ChildProcess) {
  return new Promise<number | null>((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Runtime log child timeout')); }, 12000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('exit', code => { clearTimeout(timer); resolve(code); });
  });
}

async function childApp(f: ReturnType<typeof fixture>) {
  const child = fork(resolve('dist/test/runtime-log-child.js'), [f.settings.directory],
    { cwd: f.root, execArgv: [], silent: true, windowsHide: true });
  let output = '', errors = '';
  child.stdout!.on('data', data => { output += String(data); });
  child.stderr!.on('data', data => { errors += String(data); });
  const exited = exitOf(child);
  // Register the rejection handler immediately, including failed readiness/cleanup paths.
  void exited.catch(() => {});
  f.cleanup.push(async () => { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited; });
  const first = await new Promise<{ port: number }>((resolve, reject) => {
    child.once('message', message => resolve(message as { port: number }));
    child.once('exit', () => reject(new Error('Child exited before ready')));
    child.once('error', reject);
  });
  assert(Number.isInteger(first.port));
  return { child, exited, base: `http://127.0.0.1:${first.port}`, output: () => output, errors: () => errors };
}

test('runtime log config is opt-in, bounded, absolute and separate from the business database', () => {
  assert.equal(readConfig({ DATABASE_PATH: ':memory:' }).runtimeLog, undefined);
  const directory = resolve('synthetic-runtime-logs');
  assert.deepEqual(readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: directory }).runtimeLog,
    { directory, maxBytes: 1048576, maxFiles: 5 });
  for (const input of [{ RUNTIME_LOG_DIRECTORY: 'relative' }, { RUNTIME_LOG_MAX_FILES: '1' },
    { RUNTIME_LOG_MAX_FILES: '101' }, { RUNTIME_LOG_MAX_BYTES: '1023' }, { RUNTIME_LOG_MAX_BYTES: 'NaN' },
    { RUNTIME_LOG_MAX_BYTES: String(16 * 1024 * 1024 + 1) }]) {
    assert.throws(() => readConfig({ ...input, DATABASE_PATH: ':memory:' }), /运行日志配置无效/);
  }
  assert.throws(() => readConfig({ RUNTIME_LOG_DIRECTORY: directory, DATABASE_PATH: join(directory, 'data.sqlite') }), /业务数据库必须/);
});

test('runtime projection allowlists values and never serializes arbitrary fields or custom error names', () => {
  const secret = 'private-token\n{"forged":true}';
  const requestId = randomUUID();
  const event = projectRuntimeEvent({ event: 'huawei_push_rejected', requestId, type: secret,
    repairId: secret, code: { secret }, role: secret, httpStatus: 502, statusCode: Infinity, reason: secret,
    headers: { Authorization: secret }, toJSON() { throw new Error('must not serialize'); } }, 0);
  assert.deepEqual(event, { version: 1, at: '1970-01-01T00:00:00.000Z', event: 'huawei_push_rejected', requestId, type: 'other', httpStatus: 502 });
  assert.equal(projectRuntimeEvent({ event: secret, requestId: secret }).event, 'unclassified');
  const request = projectRuntimeEvent({ method: secret, status: '500', durationMs: NaN, requestId: secret });
  assert.equal(request.method, 'OTHER');
  assert.equal(request.status, undefined);
  assert.equal(request.durationMs, undefined);
  assert.equal(request.requestId, undefined);
  assert.equal(projectRuntimeEvent({ method: 'GET', durationMs: 1e99 }).durationMs, 86400000);
});

test('runtime records are bounded JSON lines with receipt IDs, and close flushes and releases the lock', t => {
  const f = fixture(t), log = f.open(), requestId = randomUUID();
  log.write({ ...access(requestId), token: 'never-on-disk', body: 'never-on-disk' });
  log.write({ event: 'internal_error', requestId, type: 'TypeError', message: 'never-on-disk' });
  log.close();
  assert.equal(log.failed, false);
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
  const rows = records(f.settings.directory);
  assert.deepEqual(rows.map(row => row.event), ['runtime_log_started', 'request_completed', 'internal_error', 'runtime_log_stopped']);
  assert.equal(rows[1]!.requestId, requestId);
  assert.equal(rows[2]!.type, 'TypeError');
  assert(!JSON.stringify(rows).includes('never-on-disk'));
  const before = contents(f.settings.directory);
  log.close(); log.write(access());
  assert.deepEqual(contents(f.settings.directory), before);
});

test('rotation and retention keep newest records within file count and byte limits across restarts', t => {
  const f = fixture(t), first = f.open();
  for (let i = 0; i < 100; i++) first.write(access());
  const lastId = randomUUID(); first.write(access(lastId)); first.close();
  const oldNames = segments(f.settings.directory);
  assert.equal(oldNames.length, 3);
  const second = f.open(); second.close();
  const names = segments(f.settings.directory);
  assert.equal(names.length, 3);
  assert(names.at(-1)! > oldNames.at(-1)!);
  assert(records(f.settings.directory).some(row => row.requestId === lastId));
  for (const name of names) assert(statSync(join(f.settings.directory, name)).size <= f.settings.maxBytes);
  assert.equal(second.failed, false);
});

test('restart preserves a crash tail and starts a separate segment', t => {
  const f = fixture(t), first = f.open(); first.close();
  const last = join(f.settings.directory, segments(f.settings.directory).at(-1)!);
  fs.appendFileSync(last, '{"incomplete":');
  const previous = readFileSync(last);
  const second = f.open(); second.write(access()); second.close();
  assert.deepEqual(readFileSync(last), previous);
  assert.equal(segments(f.settings.directory).length, 2);
  assert.equal(JSON.parse(readFileSync(join(f.settings.directory, segments(f.settings.directory).at(-1)!), 'utf8').split('\n')[0]!).event, 'runtime_log_started');
});

test('active and unidentifiable locks block other writers without changing any file', t => {
  const f = fixture(t), first = f.open();
  const before = contents(f.settings.directory);
  assert.throws(() => f.open(), /锁被占用/);
  assert.deepEqual(contents(f.settings.directory), before);
  first.close();
  writeFileSync(join(f.settings.directory, 'writer.lock'), 'stale-lock');
  const stopped = contents(f.settings.directory);
  assert.throws(() => f.open(), /锁被占用/);
  assert.deepEqual(contents(f.settings.directory), stopped);
});

test('existing foreign directories, different database identities and unexpected files are not adopted', t => {
  const f = fixture(t);
  mkdirSync(f.settings.directory);
  writeFileSync(join(f.settings.directory, 'unrelated.txt'), 'keep');
  const before = contents(f.settings.directory);
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.deepEqual(contents(f.settings.directory), before);
  const directory = join(f.root, 'owned');
  f.settings.directory = directory;
  const log = f.open(); log.close();
  const owned = contents(directory);
  assert.throws(() => f.open('different-database'), /运行日志目录不可用/);
  assert.deepEqual(contents(directory), owned);
  writeFileSync(join(directory, 'unrelated.txt'), 'keep');
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.equal(readFileSync(join(directory, 'unrelated.txt'), 'utf8'), 'keep');
});

test('symbolic directories and hardlinked segments are rejected without touching the target', t => {
  const f = fixture(t), log = f.open(); log.close();
  const original = f.settings.directory, before = contents(original);
  const alias = join(f.root, 'alias');
  symlinkSync(original, alias, process.platform === 'win32' ? 'junction' : 'dir');
  f.settings.directory = alias;
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.deepEqual(contents(original), before);
  f.settings.directory = original;
  const target = join(original, segments(original)[0]!);
  linkSync(target, join(f.root, 'hardlink.jsonl'));
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.deepEqual(contents(original), before);
});

test('oversized old segments and invalid sequence values fail before acquiring a lock or deleting history', t => {
  const f = fixture(t), log = f.open(); log.close();
  const file = join(f.settings.directory, segments(f.settings.directory)[0]!);
  truncateSync(file, f.settings.maxBytes + 1);
  const before = contents(f.settings.directory);
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.deepEqual(contents(f.settings.directory), before);
  truncateSync(file, 0);
  writeFileSync(join(f.settings.directory, 'runtime-9999999999999999.jsonl'), '');
  assert.throws(() => f.open(), /运行日志目录不可用/);
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
});

test('truncation makes failure sticky, emits one fixed warning and never throws from request logging', t => {
  const f = fixture(t);
  let warnings = 0;
  const log = new RuntimeLog(f.settings, 'fixture', () => { warnings++; throw new Error('stderr unavailable'); });
  f.cleanup.push(() => log.close());
  truncateSync(join(f.settings.directory, segments(f.settings.directory)[0]!), 0);
  assert.doesNotThrow(() => log.write(access()));
  assert.equal(log.healthy, false);
  for (let i = 0; i < 10; i++) log.write(access());
  log.close();
  assert.equal(warnings, 1);
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
});

test('partial writes are completed, while write and fsync errors mark failure without leaking exception text', t => {
  const f = fixture(t), log = f.open();
  const realWrite = fs.writeSync;
  const partial = t.mock.method(fs, 'writeSync', (fd: number, buffer: Uint8Array, offset: number, length: number) =>
    realWrite(fd, buffer, offset, Math.min(length, 7)));
  syncBuiltinESMExports();
  try { log.write(access()); } finally { partial.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(log.healthy, true);
  assert.equal(records(f.settings.directory).at(-1)!.event, 'request_completed');
  const failedWrite = t.mock.method(fs, 'writeSync', () => { throw new Error('private-disk-error'); });
  syncBuiltinESMExports();
  try { assert.doesNotThrow(() => log.write(access())); } finally { failedWrite.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(log.failed, true);
  log.close();
  const second = f.open();
  const failedSync = t.mock.method(fs, 'fsyncSync', () => { throw new Error('private-sync-error'); });
  syncBuiltinESMExports();
  try { assert.doesNotThrow(() => second.close()); } finally { failedSync.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(second.failed, true);
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
  assert(!JSON.stringify(records(f.settings.directory)).includes('private-'));
});

test('rotation failure is visible and does not delete a foreign collision', t => {
  const f = fixture(t), log = f.open();
  const collision = join(f.settings.directory, 'runtime-0000000000000002.jsonl');
  mkdirSync(collision);
  for (let i = 0; i < 20; i++) assert.doesNotThrow(() => log.write(access()));
  assert.equal(log.failed, true);
  assert(statSync(collision).isDirectory());
});

test('close never deletes a lock replaced by another owner', t => {
  const f = fixture(t), log = f.open(), lockPath = join(f.settings.directory, 'writer.lock');
  writeFileSync(lockPath, 'replacement-owner');
  log.close();
  assert.equal(log.failed, true);
  assert.equal(readFileSync(lockPath, 'utf8'), 'replacement-owner');
});

test('real HTTP error receipt survives close and restart while malicious fields are absent from disk', async t => {
  const f = fixture(t), instance = await httpApp(f);
  const original = instance.store.one;
  instance.store.one = () => { const error = new Error('private-token'); error.name = '13800138000'; throw error; };
  const response = await fetch(`${instance.base}/ready?password=private-password`, {
    headers: { 'X-Request-Id': 'forged-request-id', Authorization: 'Bearer private-token' },
  });
  instance.store.one = original;
  const requestId = response.headers.get('x-request-id');
  assert.equal(response.status, 500);
  const rows = records(f.settings.directory);
  assert(rows.some(row => row.event === 'internal_error' && row.requestId === requestId && row.type === 'other'));
  assert(rows.some(row => row.event === 'request_completed' && row.requestId === requestId && row.status === 500));
  assert(instance.observed.some((row: any) => row.type === '13800138000')); // Existing injected callback is unchanged.
  const output = JSON.stringify(rows) + await response.text();
  assert.doesNotMatch(output, /private-token|private-password|13800138000|forged-request-id/);
  await f.cleanup.pop()!();
  const second = await httpApp(f);
  assert.equal((await fetch(`${second.base}/ready`)).status, 200);
  assert(records(f.settings.directory).some(row => row.requestId === requestId));
});

test('write failure makes subsequent readiness return 503 while health and business process remain alive', async t => {
  const f = fixture(t), instance = await httpApp(f);
  const warnings: string[] = [];
  const stderr = t.mock.method(process.stderr, 'write', (chunk: string | Uint8Array) => { warnings.push(String(chunk)); return true; });
  try {
    truncateSync(join(f.settings.directory, segments(f.settings.directory)[0]!), 0);
    assert.equal((await fetch(`${instance.base}/health`)).status, 200);
    assert.equal((await fetch(`${instance.base}/ready`)).status, 503);
    assert.equal((await fetch(`${instance.base}/ready`)).status, 503);
  } finally { stderr.mock.restore(); }
  assert.deepEqual(warnings, ['{"event":"runtime_log_failed"}\n']);
  assert.equal(instance.runtimeLog!.failed, true);
});

test('log startup failure precedes business database creation and leaves existing contents alone', t => {
  const f = fixture(t), database = join(f.root, 'never-created.sqlite');
  mkdirSync(f.settings.directory);
  const config = readConfig({ DATABASE_PATH: database, RUNTIME_LOG_DIRECTORY: f.settings.directory });
  assert.throws(() => createApp(config, { pushTimer: false }), /运行日志目录不可用/);
  assert.equal(existsSync(database), false);
  assert.deepEqual(readdirSync(f.settings.directory), []);
});

test('database and later initialization failures release log resources and allow a clean retry', t => {
  const f = fixture(t), config = readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: f.settings.directory });
  const bind = t.mock.method(Store.prototype, 'bindEnvironment', () => { throw new Error('controlled-binding-failure'); });
  try { assert.throws(() => createApp(config, { pushTimer: false }), /controlled-binding-failure/); }
  finally { bind.mock.restore(); }
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
  const instance = createApp(config, { pushTimer: false, log: () => {} }); instance.store.close();
  assert.equal(instance.runtimeLog!.failed, false);
  const settle = t.mock.method(RepairService.prototype, 'settleAll', () => { throw new Error('controlled-startup-failure'); });
  try { assert.throws(() => createApp(config, { pushTimer: false }), /controlled-startup-failure/); }
  finally { settle.mock.restore(); }
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
  // Constructor failure must also release the log opened before the database.
  const brokenDatabase = join(f.root, 'broken.sqlite');
  writeFileSync(brokenDatabase, 'not-a-database');
  const secondDirectory = join(f.root, 'other-logs');
  assert.throws(() => createApp(readConfig({ DATABASE_PATH: brokenDatabase, RUNTIME_LOG_DIRECTORY: secondDirectory }), { pushTimer: false }));
  assert.equal(existsSync(join(secondDirectory, 'writer.lock')), false);
});

test('separate service process persists sanitized stdout and receipts and flushes on orderly close', async t => {
  const f = fixture(t), c = await childApp(f);
  const poisoned = new Promise<void>(resolve => c.child.once('message', () => resolve()));
  c.child.send('poison'); await poisoned;
  const response = await fetch(`${c.base}/ready`);
  const requestId = response.headers.get('x-request-id');
  assert.equal(response.status, 500);
  await response.text();
  c.child.send('close');
  assert.equal(await c.exited, 0);
  const rows = records(f.settings.directory);
  assert(rows.some(row => row.requestId === requestId && row.event === 'internal_error'));
  assert.equal(rows.at(-1)!.event, 'runtime_log_stopped');
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
  assert.doesNotMatch(c.output() + c.errors() + JSON.stringify(rows), /private-example|private-token|13800138000|private-error-name/);
});

test('unsupported database schema and failed migrations close their native connection', t => {
  const f = fixture(t);
  const unsupported = join(f.root, 'unsupported.sqlite');
  let db = new DatabaseSync(unsupported);
  db.exec('PRAGMA user_version = 999'); db.close();
  const incomplete = join(f.root, 'incomplete.sqlite');
  db = new DatabaseSync(incomplete);
  db.exec('PRAGMA user_version = 12'); db.close();
  const realClose = DatabaseSync.prototype.close;
  let closed = 0;
  const close = t.mock.method(DatabaseSync.prototype, 'close', function (this: DatabaseSync) {
    closed++; return realClose.call(this);
  });
  try {
    assert.throws(() => new Store(unsupported), /数据库版本不兼容/);
    assert.throws(() => new Store(incomplete));
    assert.equal(closed, 2);
  } finally { close.mock.restore(); }
});

test('forced service termination recovers the stale lock and preserves existing history', async t => {
  const f = fixture(t), c = await childApp(f);
  assert.equal((await fetch(`${c.base}/health`)).status, 200);
  c.child.kill('SIGKILL'); await c.exited;
  const before = records(f.settings.directory);
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), true);
  const instance = createApp(readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: f.settings.directory }), { pushTimer: false });
  assert.throws(() => createApp(readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: f.settings.directory }), { pushTimer: false }), /锁被占用/);
  instance.store.close();
  const after = records(f.settings.directory);
  for (const row of before) assert(after.some(saved => JSON.stringify(saved) === JSON.stringify(row)));
  assert(after.some(row => row.event === 'process_lock_recovered'));
  assert.equal(existsSync(join(f.settings.directory, 'writer.lock')), false);
});

test('compiled main releases the log lock on listen failure and maintenance does not open log or business directories', async t => {
  const f = fixture(t), blocker = createServer();
  await new Promise<void>(resolve => blocker.listen(0, '127.0.0.1', resolve));
  f.cleanup.push(() => new Promise<void>(resolve => blocker.close(() => resolve())));
  const address = blocker.address(); assert(address && typeof address !== 'string');
  const run = async (maintenance: boolean) => {
    const child = spawn(process.execPath, [resolve('dist/src/main.js')], { cwd: f.root, windowsHide: true,
      env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, USERDOMAIN: process.env.USERDOMAIN,
        DATABASE_PATH: join(f.root, maintenance ? 'maintenance.sqlite' : 'normal.sqlite'), PORT: String(address.port),
        AUTH_MODE: 'development', MAINTENANCE_MODE: String(maintenance), RUNTIME_LOG_DIRECTORY: join(f.root, maintenance ? 'maintenance-logs' : 'main-logs') },
      stdio: ['ignore', 'pipe', 'pipe'] });
    let output = ''; child.stdout.on('data', data => { output += String(data); }); child.stderr.on('data', data => { output += String(data); });
    const exited = exitOf(child); void exited.catch(() => {});
    f.cleanup.push(async () => { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited; });
    assert.equal(await exited, 1);
    assert(output.includes('server_listen_failed'));
    return output;
  };
  await run(false);
  assert.equal(existsSync(join(f.root, 'main-logs', 'writer.lock')), false);
  assert.equal(records(join(f.root, 'main-logs')).at(-1)!.event, 'runtime_log_stopped');
  await run(true);
  assert.equal(existsSync(join(f.root, 'maintenance-logs')), false);
  assert.equal(existsSync(join(f.root, 'maintenance.sqlite')), false);
});
