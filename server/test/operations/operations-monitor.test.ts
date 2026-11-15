import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type RequestListener } from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { OperationsJournal, operationsMonitorConfigSchema, readOperationsMonitorConfig, runOperationsMonitor,
  type OperationsMonitorConfig, type MonitorEvent } from '../../src/operations-monitor.js';
import { OperationsMetrics } from '../../src/operations.js';

function temporary(t: TestContext) {
  const directory = mkdtempSync(join(tmpdir(), 'haven-monitor-'));
  t.after(() => {
    assert.equal(dirname(directory), tmpdir());
    assert(basename(directory).startsWith('haven-monitor-'));
    rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}

function settings(directory: string): OperationsMonitorConfig {
  return { directory: join(directory, 'journal'), checkConfigFile: join(directory, 'check.json'),
    intervalSeconds: 30, failureSamples: 2, recoverySamples: 2, retentionEvents: 100 };
}
const good = { status: 'ok', reasons: [] };
const bad = { status: 'alert', reasons: ['push_stopped'] };
const unavailable = { status: 'unavailable', reasons: ['probe_failed'] };
const unknown = { status: 'insufficient-data', reasons: [] };
const maintenance = { status: 'maintenance', reasons: ['maintenance_mode'] };
const eventsOf = (events: MonitorEvent[]) => events.map(event => event.event);
function inspect(config: OperationsMonitorConfig) {
  const db = new DatabaseSync(join(config.directory, 'monitor.sqlite'), { readOnly: true });
  try { return { events: db.prepare('SELECT * FROM events ORDER BY seq').all(),
    state: JSON.parse(String(db.prepare('SELECT incident FROM state WHERE id=1').get()!.incident)) }; }
  finally { db.close(); }
}

test('monitor confirms consecutive failures, deduplicates repeats and confirms recovery', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  try {
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
    journal.record(good); // resets failure streak
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
    const opened = journal.record(unavailable);
    assert.deepEqual(eventsOf(opened), ['sample', 'incident_opened']);
    const id = opened[1]!.incidentId;
    assert(id);
    assert.deepEqual(eventsOf(journal.record(unavailable)), ['sample']);
    const changed = journal.record(bad);
    assert.deepEqual(eventsOf(changed), ['sample', 'incident_updated']);
    assert.equal(changed[1]!.incidentId, id);
    assert.deepEqual(eventsOf(journal.record(good)), ['sample']);
    const recovered = journal.record(good);
    assert.deepEqual(eventsOf(recovered), ['sample', 'incident_recovered']);
    assert.equal(recovered[1]!.incidentId, id);
    assert.deepEqual(eventsOf(journal.record(good)), ['sample']);
    assert.equal(inspect(config).state, null);
  } finally { journal.close(); }
});

test('maintenance and insufficient data reset streaks without declaring incident recovery', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  try {
    journal.record(bad); journal.record(unknown);
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
    journal.record(bad); journal.record(good); journal.record(maintenance);
    assert.deepEqual(eventsOf(journal.record(good)), ['sample']);
    journal.record(unknown);
    assert(inspect(config).state);
    assert.deepEqual(eventsOf(journal.record(good)), ['sample']);
    assert.deepEqual(eventsOf(journal.record(good)), ['sample', 'incident_recovered']);
  } finally { journal.close(); }
});

test('restart preserves incident identity but resets partial confirmation streaks', t => {
  const config = settings(temporary(t));
  let journal = new OperationsJournal(config, 'target');
  journal.record(bad); journal.close();
  journal = new OperationsJournal(config, 'target');
  assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
  const id = journal.record(bad)[1]!.incidentId;
  journal.record(good); journal.close();
  journal = new OperationsJournal(config, 'target');
  try {
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
    journal.record(good);
    assert.equal(journal.record(good)[1]!.incidentId, id);
  } finally { journal.close(); }
});

test('sample and transition writes roll back together; failed writes do not advance confirmation', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  const editor = new DatabaseSync(join(config.directory, 'monitor.sqlite'));
  try {
    editor.exec("CREATE TRIGGER fail_sample BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test disk failure'); END");
    assert.throws(() => journal.record(bad));
    assert.equal(inspect(config).events.length, 0);
    editor.exec('DROP TRIGGER fail_sample');
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample']);
    editor.exec("CREATE TRIGGER fail_state BEFORE UPDATE ON state BEGIN SELECT RAISE(ABORT,'test disk failure'); END");
    assert.throws(() => journal.record(bad));
    assert.equal(inspect(config).events.length, 1);
    assert.equal(inspect(config).state, null);
    editor.exec('DROP TRIGGER fail_state');
    assert.deepEqual(eventsOf(journal.record(bad)), ['sample', 'incident_opened']);
  } finally { editor.close(); journal.close(); }
});

test('event retention keeps the active incident independently and orders by sequence under clock rollback', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  try {
    journal.record(bad, 20000);
    const id = journal.record(bad, 10000)[1]!.incidentId;
    for (let i = 0; i < 150; i++) journal.record(bad, 5000 - i);
    const saved = inspect(config);
    assert.equal(saved.events.length, 100);
    assert.equal(saved.state.id, id);
    assert(saved.events.every(event => event.event === 'sample'));
    assert(Number(saved.events.at(-1)!.seq) > Number(saved.events[0]!.seq));
    journal.record(good);
    assert.equal(journal.record(good)[1]!.incidentId, id);
    assert.equal(inspect(config).events.length, 100);
  } finally { journal.close(); }
});

test('journal refuses concurrent writers and changed target; closing releases only its own lock', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  const lock = join(config.directory, 'collector.lock');
  const original = readFileSync(lock, 'utf8');
  assert.throws(() => new OperationsJournal(config, 'target'), /锁被占用/);
  assert.equal(readFileSync(lock, 'utf8'), original);
  journal.close();
  assert.equal(existsSync(lock), false);
  assert.throws(() => new OperationsJournal(config, 'another-target'), /配置已变化/);
  assert.equal(existsSync(lock), false);
  const reopened = new OperationsJournal(config, 'target'); reopened.close(); reopened.close();
});

test('journal recovers a dead process lock without losing the existing incident', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  journal.record(bad);
  const incidentId = journal.record(bad)[1]!.incidentId;
  journal.close();
  const child = spawnSync(process.execPath, ['-e', 'process.stdout.write(JSON.stringify({pid:process.pid,startedAt:new Date(performance.timeOrigin).toISOString()}))'], { encoding: 'utf8', windowsHide: true });
  assert.equal(child.status, 0);
  writeFileSync(join(config.directory, 'collector.lock'), child.stdout);
  const claim = join(config.directory, `collector.lock.reclaim-${createHash('sha256').update(child.stdout).digest('hex').slice(0, 16)}`);
  writeFileSync(claim, child.stdout);
  const messages: string[] = [];
  const stderr = t.mock.method(process.stderr, 'write', (chunk: unknown) => { messages.push(String(chunk)); return true; });
  try {
    const recovered = new OperationsJournal(config, 'target');
    try { assert.equal(inspect(config).state.id, incidentId); }
    finally { recovered.close(); }
  } finally { stderr.mock.restore(); }
  assert(messages.some(line => line.includes('collector_lock_recovered')));
  assert(!existsSync(claim));
});

test('journal does not reset corrupt state, reuse unknown directory content or import raw report details', t => {
  const config = settings(temporary(t));
  const journal = new OperationsJournal(config, 'target');
  journal.record({ ...bad, secret: 'private-token', message: 'private-error' });
  journal.record({ ...bad, reasons: ['push_stopped', 'push_stopped'] });
  assert.throws(() => journal.record({ status: 'ok', reasons: ['private-error'] }));
  journal.close();
  assert.doesNotMatch(JSON.stringify(inspect(config)), /private-token|private-error/);
  const db = new DatabaseSync(join(config.directory, 'monitor.sqlite'));
  db.prepare('UPDATE state SET incident=?').run('invalid'); db.close();
  assert.throws(() => new OperationsJournal(config, 'target'));
  assert.equal(existsSync(join(config.directory, 'collector.lock')), false);
  writeFileSync(join(config.directory, 'unrelated.txt'), 'keep');
  assert.throws(() => new OperationsJournal(config, 'target'), /未知内容/);
  assert.equal(readFileSync(join(config.directory, 'unrelated.txt'), 'utf8'), 'keep');
});

test('monitor config enforces explicit limits and resolves paths relative to its file', t => {
  const root = temporary(t);
  const config = settings(root);
  for (const patch of [{ intervalSeconds: 0 }, { intervalSeconds: 29 }, { intervalSeconds: 3601 },
    { failureSamples: 0 }, { recoverySamples: 11 }, { retentionEvents: 99 }, { retentionEvents: 100001 }]) {
    assert.equal(operationsMonitorConfigSchema.safeParse({ ...config, ...patch }).success, false);
  }
  const file = join(root, 'monitor.json');
  writeFileSync(file, JSON.stringify({ ...config, checkConfigFile: 'check.json', directory: 'journal' }));
  assert.deepEqual(readOperationsMonitorConfig(file), config);
});

async function service(t: TestContext, listener?: RequestListener) {
  let status = 'ok';
  let inFlight = 0;
  let maximumInFlight = 0;
  const seenTokens: string[] = [];
  const counts = new OperationsMetrics(() => 0);
  counts.begin(false)({ status: 200, businessError: false });
  const snapshot = { schemaVersion: 1, generatedAt: Date.now(), requests: counts.snapshot(),
    push: { activeDeliveries: 0, queued: 0, failed: 0, sending: 0, accepted: 0, unconfigured: 0,
      expired: 0, unknownStatus: 0, stopped: 0, expiredLeases: 0, orphaned: 0, due: 0, oldestDueDelayMs: null } };
  const server = createServer(listener ?? ((req, res) => {
    inFlight++; maximumInFlight = Math.max(maximumInFlight, inFlight);
    res.on('finish', () => { inFlight--; });
    if (status === 'unavailable') { res.statusCode = 503; res.end(); return; }
    if (req.url === '/operations/snapshot') seenTokens.push(req.headers.authorization ?? '');
    res.end(JSON.stringify({ code: 10000, data: req.url === '/health' ? { mode: status === 'maintenance' ? 'maintenance' : 'production' }
      : req.url === '/ready' ? { ready: true } : snapshot }));
  })).listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const address = server.address(); assert(address && typeof address !== 'string');
  const root = temporary(t);
  const config = settings(root);
  const tokenFile = join(root, 'token.json');
  writeFileSync(tokenFile, JSON.stringify({ token: 'ops_v1_' + 'a'.repeat(64) }));
  const check = { baseUrl: `http://127.0.0.1:${address.port}`, tokenFile, authentication: 'operations-key',
    clientVersion: '1.0.0', timeoutMs: 5000, thresholds: { minimumRequests: 1, maxServerErrorRate: 0,
      maxAuthRejected: 0, maxAborted: 0, maxP95Ms: 10000, maxDue: 0, maxDueDelayMs: 0, maxStopped: 0,
      maxExpiredLeases: 0, maxUnconfigured: 0, maxBackgroundFailures: 0 } };
  writeFileSync(config.checkConfigFile, JSON.stringify(check));
  return { config, tokenFile, check, setStatus: (value: string) => { status = value; }, seenTokens,
    maximum: () => maximumInFlight };
}

test('serial collector observes failure and recovery via real HTTP and reloads replaced token files', async t => {
  const f = await service(t);
  const events: MonitorEvent[] = [];
  let waits = 0;
  const output = await runOperationsMonitor(f.config, { cycles: 6, emit: event => events.push(event), wait: async milliseconds => {
    assert.equal(milliseconds, 30000);
    waits++;
    if (waits === 1) f.setStatus('unavailable');
    if (waits === 4) {
      f.setStatus('ok');
      writeFileSync(f.tokenFile, JSON.stringify({ token: 'ops_v1_' + 'b'.repeat(64) }));
    }
  } });
  assert.equal(output.samples, 6);
  assert.equal(waits, 5);
  assert.equal(f.maximum(), 1);
  assert.deepEqual(events.filter(event => event.event !== 'sample').map(event => event.event),
    ['collector_started', 'incident_opened', 'incident_recovered', 'collector_stopped']);
  assert.deepEqual(f.seenTokens, ['Bearer ops_v1_' + 'a'.repeat(64), 'Bearer ops_v1_' + 'b'.repeat(64), 'Bearer ops_v1_' + 'b'.repeat(64)]);
  assert.doesNotMatch(JSON.stringify(inspect(f.config)), /ops_v1_|Bearer|token\.json/);
  assert.equal(existsSync(join(f.config.directory, 'collector.lock')), false);
});

test('missing credential is journalled and recovery is possible without restarting the collector', async t => {
  const f = await service(t);
  unlinkSync(f.tokenFile);
  let waits = 0;
  const events: MonitorEvent[] = [];
  await runOperationsMonitor(f.config, { cycles: 4, emit: event => events.push(event), wait: async () => {
    if (++waits === 2) writeFileSync(f.tokenFile, JSON.stringify({ token: 'ops_v1_' + 'a'.repeat(64) }));
  } });
  const opened = events.find(event => event.event === 'incident_opened')!;
  assert.deepEqual(opened.reasons, ['credential_file_unavailable']);
  assert.equal(events.find(event => event.event === 'incident_recovered')!.incidentId, opened.incidentId);
});

test('explicit shutdown cancels a streaming probe and never records it as an outage', async t => {
  const stop = new AbortController();
  const f = await service(t, (_req, res) => { res.writeHead(200); res.write('{'); stop.abort(); });
  const events: MonitorEvent[] = [];
  const started = performance.now();
  const result = await runOperationsMonitor(f.config, { signal: stop.signal, emit: event => events.push(event) });
  assert.equal(result.samples, 0);
  assert(performance.now() - started < 3000);
  assert.deepEqual(eventsOf(events), ['collector_started', 'collector_stopped']);
  assert.equal(existsSync(join(f.config.directory, 'collector.lock')), false);
});

test('stop during interval wakes the collector and emits one orderly stop', async t => {
  const f = await service(t);
  const stop = new AbortController();
  const events: MonitorEvent[] = [];
  const result = await runOperationsMonitor(f.config, { signal: stop.signal, emit: event => {
    events.push(event);
    if (event.event === 'sample') setTimeout(() => stop.abort(), 20);
  } });
  assert.equal(result.samples, 1);
  assert.equal(events.filter(event => event.event === 'collector_stopped').length, 1);
});

test('storage failure stops collection with no false clean-stop event and releases the process lock', async t => {
  const f = await service(t);
  const events: MonitorEvent[] = [];
  await assert.rejects(runOperationsMonitor(f.config, { cycles: 2, emit: event => events.push(event), wait: async () => {
    const db = new DatabaseSync(join(f.config.directory, 'monitor.sqlite'));
    db.exec("CREATE TRIGGER fail_monitor_write BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test disk failure'); END");
    db.close();
  } }));
  assert.equal(events.filter(event => event.event === 'sample').length, 1);
  assert.equal(events.filter(event => event.event === 'collector_stopped').length, 0);
  assert.equal(existsSync(join(f.config.directory, 'collector.lock')), false);
});

test('continuous monitor requires machine mode and binds persisted incident state to target and thresholds', async t => {
  const f = await service(t);
  writeFileSync(f.config.checkConfigFile, JSON.stringify({ ...f.check, authentication: 'admin-session' }));
  await assert.rejects(runOperationsMonitor(f.config, { cycles: 1 }), /独立只读凭证/);
  assert.equal(existsSync(f.config.directory), false);
  writeFileSync(f.config.checkConfigFile, JSON.stringify(f.check));
  await runOperationsMonitor(f.config, { cycles: 1, emit: () => {} });
  writeFileSync(f.config.checkConfigFile, JSON.stringify({ ...f.check, thresholds: { ...f.check.thresholds, minimumRequests: 2 } }));
  await assert.rejects(runOperationsMonitor(f.config, { cycles: 1 }), /配置已变化/);
});

test('independent collector CLI records a finite run, reloads persisted incident and hides configuration errors', async t => {
  const f = await service(t);
  const config = { ...f.config, failureSamples: 1, recoverySamples: 1 };
  const path = join(dirname(f.config.checkConfigFile), 'monitor.json');
  writeFileSync(path, JSON.stringify(config));
  const run = () => new Promise<{ code: number | null; output: string }>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'tool/operations-monitor.ts', path, '--cycles', '1'],
      { cwd: fileURLToPath(new URL('../../', import.meta.url)), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', data => { output += String(data); });
    child.stderr.on('data', data => { output += String(data); });
    child.on('error', reject); child.on('close', code => resolve({ code, output }));
  });
  f.setStatus('unavailable');
  const opened = await run();
  assert.equal(opened.code, 0, opened.output);
  assert.match(opened.output, /incident_opened/);
  const duplicate = await run();
  assert.equal(duplicate.code, 0);
  assert.doesNotMatch(duplicate.output, /incident_opened|incident_recovered/);
  f.setStatus('ok');
  const recovered = await run();
  assert.equal(recovered.code, 0);
  assert.match(recovered.output, /incident_recovered/);
  writeFileSync(path, 'invalid private-config');
  const failed = await run();
  assert.equal(failed.code, 1);
  assert.match(failed.output, /collector_failed/);
  assert.doesNotMatch(opened.output + duplicate.output + recovered.output + failed.output, /ops_v1_|private-config|monitor\.json/);
});
