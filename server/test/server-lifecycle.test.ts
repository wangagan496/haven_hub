import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { fork, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readFileSync, readdirSync, rmSync, existsSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { createServer } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';

function fixture(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'haven-server-lifecycle-'));
  const cleanup: Array<() => Promise<unknown>> = [];
  t.after(async () => {
    for (const close of cleanup.reverse()) await close();
    assert.equal(dirname(root), tmpdir());
    assert(basename(root).startsWith('haven-server-lifecycle-'));
    rmSync(root, { recursive: true, force: true });
  });
  return { root, cleanup };
}

async function freePort() {
  const server = createServer();
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address(); assert(address && typeof address !== 'string');
  await new Promise<void>(resolve => server.close(() => resolve()));
  return address.port;
}

function completion(child: ChildProcess) {
  return new Promise<number | null>((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Lifecycle child timed out')); }, 15000);
    child.once('error', error => { clearTimeout(timer); reject(error); });
    child.once('close', code => { clearTimeout(timer); resolve(code); });
  });
}

async function start(f: ReturnType<typeof fixture>, extra: NodeJS.ProcessEnv = {}, entry = 'server-shutdown-child.js') {
  const port = await freePort(), reportPath = join(f.root, 'report.json');
  const child = fork(resolve('dist/test', entry), [reportPath], { cwd: f.root, execArgv: [], silent: true, windowsHide: true,
    env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, USERDOMAIN: process.env.USERDOMAIN,
      NODE_ENV: 'test', HOST: '127.0.0.1', PORT: String(port), AUTH_MODE: 'development',
      DATABASE_PATH: join(f.root, 'database.sqlite'), RUNTIME_LOG_DIRECTORY: join(f.root, 'logs'), ...extra } });
  let output = '';
  child.stdout!.on('data', data => { output += String(data); });
  child.stderr!.on('data', data => { output += String(data); });
  const exited = completion(child); void exited.catch(() => {});
  f.cleanup.push(async () => { if (child.exitCode === null && child.signalCode === null) child.kill(); await exited; });
  return { child, exited, reportPath, output: () => output, base: `http://127.0.0.1:${port}` };
}

function events(f: ReturnType<typeof fixture>): Array<{ event: string }> {
  const directory = join(f.root, 'logs');
  return readdirSync(directory).filter(name => name.endsWith('.jsonl')).sort().flatMap(name =>
    readFileSync(join(directory, name), 'utf8').trim().split('\n').filter(Boolean).map(line => JSON.parse(line)));
}

async function ready(c: Awaited<ReturnType<typeof start>>) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (c.child.exitCode !== null || c.child.signalCode !== null) throw new Error('Lifecycle service exited before readiness');
    try { const response = await fetch(`${c.base}/health`, { signal: AbortSignal.timeout(300) }); await response.text(); if (response.ok) return; }
    catch { /* Startup is bounded by both the attempt count and child timeout. */ }
    await delay(30);
  }
  throw new Error('Lifecycle service did not become ready');
}

test('compiled main waits for background shutdown before closing the database and exits once', async t => {
  const f = fixture(t), c = await start(f); await ready(c);
  c.child.send('stop-twice');
  assert.equal(await c.exited, 0);
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.stopFinished, true);
  assert.equal(report.databaseClosedBeforeStop, false);
  assert.equal(report.databaseCloseCalls, 1);
  assert.equal(report.stopCalls, 1);
  assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
  assert.equal(events(f).filter(row => row.event === 'server_stopping').length, 1);
  assert(events(f).some(row => row.event === 'server_drained'));
  assert.match(c.output(), /server_stopped/);
});

test('compiled main rejects invalid configuration without echoing its value or stack', async t => {
  const f = fixture(t), c = await start(f, { HOST: 'private-configuration-value' });
  assert.equal(await c.exited, 1);
  assert.doesNotMatch(c.output(), /private-configuration-value|at readConfig|at file:/);
  assert.match(c.output(), /server_config_failed/);
  assert.equal(existsSync(join(f.root, 'database.sqlite')), false);
});

for (const [command, event] of [['uncaught', 'process_uncaught_exception'], ['rejection', 'process_unhandled_rejection'],
  ['stop-then-fatal', 'process_uncaught_exception']] as const) {
  test(`compiled main handles ${command} with fixed diagnostics, cleanup and a failing exit code`, async t => {
    const f = fixture(t), c = await start(f); await ready(c);
    c.child.send(command);
    assert.equal(await c.exited, 1);
    const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
    assert.equal(report.stopFinished, true);
    assert.equal(report.databaseClosedBeforeStop, false);
    assert.equal(report.databaseCloseCalls, 1);
    assert.equal(report.stopCalls, 1);
    assert.equal(events(f).filter(row => row.event === event).length, 1);
    assert.equal(events(f).filter(row => row.event === 'server_stopping').length, 1);
    assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
    assert.doesNotMatch(c.output() + JSON.stringify(events(f)), /private-|Error:|at file:/);
    assert.match(c.output(), /server_shutdown_failed/);
    assert.doesNotMatch(c.output(), /"event":"server_stopped"/);
  });
}

test('a stuck background stop reaches the real five-second deadline even after IPC disconnects', async t => {
  const f = fixture(t), c = await start(f, { TEST_STOP_MODE: 'hang' }); await ready(c);
  const started = performance.now(); c.child.send('stop-disconnect');
  assert.equal(await c.exited, 1);
  assert(performance.now() - started >= 4900);
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.stopFinished, false);
  assert.equal(report.databaseCloseCalls, 0); // Do not close an in-use connection underneath background work.
  assert(events(f).some(row => row.event === 'server_shutdown_timeout'));
  assert(!events(f).some(row => row.event === 'server_drained'));
  assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
});

for (const extra of [{ TEST_STOP_MODE: 'throw' }, { TEST_CLOSE_MODE: 'throw' }]) {
  test(`cleanup failure ${Object.keys(extra)[0]} remains sanitized and still closes the runtime log`, async t => {
    const f = fixture(t), c = await start(f, extra); await ready(c);
    c.child.send('stop-twice'); assert.equal(await c.exited, 1);
    const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
    assert.equal(report.stopCalls, 1);
    assert.equal(report.databaseCloseCalls, 1);
    assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
    assert.match(c.output(), /server_shutdown_failed/);
    assert.doesNotMatch(c.output(), /private-|Error:|at file:/);
  });
}

test('shutdown cannot report success after the log has failed', async t => {
  const f = fixture(t), c = await start(f); await ready(c);
  c.child.send('damage-log-stop');
  assert.equal(await c.exited, 1);
  assert.match(c.output(), /runtime_log_failed/);
  assert.match(c.output(), /server_shutdown_failed/);
  assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
});

test('database initialization failure is sanitized and releases the log lock', async t => {
  const f = fixture(t);
  writeFileSync(join(f.root, 'database.sqlite'), 'private-bad-database');
  const c = await start(f);
  assert.equal(await c.exited, 1);
  assert.match(c.output(), /server_start_failed/);
  assert.doesNotMatch(c.output(), /private-|Error:|at file:/);
  assert(events(f).some(row => row.event === 'server_start_failed'));
  assert.equal(existsSync(join(f.root, 'logs', 'writer.lock')), false);
});

test('maintenance shuts down without opening the business database or runtime directory', async t => {
  const f = fixture(t), c = await start(f, { MAINTENANCE_MODE: 'true' }); await ready(c);
  c.child.send('stop'); assert.equal(await c.exited, 0);
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.stopCalls, 0); assert.equal(report.databaseCloseCalls, 0);
  assert.equal(existsSync(join(f.root, 'database.sqlite')), false);
  assert.equal(existsSync(join(f.root, 'logs')), false);
  assert.match(c.output(), /server_stopped/);
});

test('fatal errors are sanitized and exit nonzero when file logging is disabled', async t => {
  const f = fixture(t), c = await start(f, { RUNTIME_LOG_DIRECTORY: '' }); await ready(c);
  c.child.send('uncaught'); assert.equal(await c.exited, 1);
  assert.match(c.output(), /process_uncaught_exception/);
  assert.doesNotMatch(c.output(), /private-|Error:|at file:/);
  assert.equal(existsSync(join(f.root, 'logs')), false);
});

test('shutdown drains a real active HTTP response before closing resources', async t => {
  const f = fixture(t), c = await start(f, { TEST_HTTP: 'true' }, 'server-drain-child.js'); await ready(c);
  const response = await fetch(`${c.base}/fixture-slow`);
  const body = response.text();
  c.child.send('stop');
  assert.equal(await body, 'first-finished');
  assert.equal(await c.exited, 0);
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.responseFinished, true);
  assert.equal(report.closedBeforeResponse, false);
  assert.equal(report.closeCalls, 1);
});

test('a stuck HTTP response is destroyed at the deadline without falsely reporting a clean drain', async t => {
  const f = fixture(t), c = await start(f, { TEST_HTTP: 'true', TEST_HTTP_TIMEOUT: 'true' }, 'server-drain-child.js'); await ready(c);
  const response = await fetch(`${c.base}/fixture-slow`);
  const body = response.text().then(() => 'completed', () => 'aborted');
  c.child.send('stop');
  assert.equal(await c.exited, 1);
  assert.equal(await body, 'aborted');
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.closeCalls, 0);
  assert(events(f).some(row => row.event === 'server_shutdown_timeout'));
  assert(!events(f).some(row => row.event === 'server_drained'));
});

test('shutdown waits for the real notification dispatcher and does not start the next queued delivery', async t => {
  const f = fixture(t), c = await start(f, {}, 'server-drain-child.js'); await ready(c);
  const sending = new Promise<void>(resolve => c.child.once('message', () => resolve()));
  c.child.send('send-push'); await sending;
  c.child.send('stop');
  assert.equal(await c.exited, 0);
  const report = JSON.parse(readFileSync(c.reportPath, 'utf8'));
  assert.equal(report.sends, 1);
  assert.equal(report.sendFinished, true);
  assert.equal(report.closedBeforeSend, false);
  assert.equal(report.closeCalls, 1);
  // Preserve the existing stop contract: an unconfirmed send keeps its lease for restart recovery.
  assert.equal(report.sending, 1); assert.equal(report.queued, 1);
});
