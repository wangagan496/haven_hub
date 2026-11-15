import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { OperationsJournal, operationsMonitorFingerprint, type OperationsMonitorConfig } from '../../src/operations-monitor.js';
import { checkOperationsMonitor } from '../../src/operations-monitor-status.js';
import { collectorReceiptSchema } from '../../src/operations-monitor-state.js';
import type { OperationsCheckConfig } from '../../src/operations-check.js';

const serverRoot = fileURLToPath(new URL('../../', import.meta.url));
const good = { status: 'ok', reasons: [] };
const failed = { status: 'unavailable', reasons: ['probe_failed'] };
const start = Date.parse('2026-10-29T02:00:00.000Z');

function fixture(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'haven-monitor-status-'));
  const config: OperationsMonitorConfig = { directory: join(root, 'journal'), checkConfigFile: join(root, 'check.json'),
    intervalSeconds: 30, failureSamples: 2, recoverySamples: 2, retentionEvents: 100 };
  const check: OperationsCheckConfig = { baseUrl: 'http://127.0.0.1:1', tokenFile: join(root, 'absent-token.json'),
    clientVersion: '1.0.0', authentication: 'operations-key', timeoutMs: 100,
    thresholds: { minimumRequests: 1, maxServerErrorRate: 0, maxAuthRejected: 0, maxAborted: 0, maxP95Ms: 10000,
      maxDue: 0, maxDueDelayMs: 0, maxStopped: 0, maxExpiredLeases: 0, maxUnconfigured: 0, maxBackgroundFailures: 0 } };
  const configFile = join(root, 'monitor.json');
  writeFileSync(config.checkConfigFile, JSON.stringify(check));
  writeFileSync(configFile, JSON.stringify(config));
  const receiptPath = join(config.directory, 'collector-status.json');
  const lockPath = join(config.directory, 'collector.lock');
  let journal: OperationsJournal | undefined;
  let ownedLock: string | undefined;
  const open = () => {
    journal = new OperationsJournal(config, operationsMonitorFingerprint(config, check));
    ownedLock = readFileSync(lockPath, 'utf8');
    return journal;
  };
  t.after(() => {
    try {
      if (ownedLock) writeFileSync(lockPath, ownedLock);
      journal?.close();
    } finally {
      assert.equal(dirname(root), tmpdir());
      assert(basename(root).startsWith('haven-monitor-status-'));
      rmSync(root, { recursive: true, force: true });
    }
  });
  const receipt = () => collectorReceiptSchema.parse(JSON.parse(readFileSync(receiptPath, 'utf8')));
  return { root, config, check, configFile, receiptPath, lockPath, open, receipt };
}

function digest(directory: string) {
  return readdirSync(directory).sort().map(name => {
    const path = join(directory, name);
    return { name, size: statSync(path).size, modified: statSync(path).mtimeMs,
      sha256: createHash('sha256').update(readFileSync(path)).digest('hex') };
  });
}

function cli(args: string[]) {
  return new Promise<{ code: number | null; stdout: string; stderr: string }>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', 'tool/operations-monitor-status.ts', ...args],
      { cwd: serverRoot, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += String(data); });
    child.stderr.on('data', data => { stderr += String(data); });
    child.once('error', reject);
    child.once('close', code => resolve({ code, stdout, stderr }));
  });
}

test('freshness uses committed samples without reading tokens or calling HTTP', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start + 1000);
  assert(!existsSync(f.check.tokenFile));
  assert.deepEqual(checkOperationsMonitor(f.config, start + 2000), {
    status: 'fresh', reasons: [], exitCode: 0, ageMs: 1000, deadlineMs: 40300,
    lastSample: { at: new Date(start + 1000).toISOString(), status: 'ok', reasons: [] },
  });
});

test('fresh collector remains separate from service failures, maintenance and low traffic', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  for (const observation of [failed, { status: 'alert', reasons: ['push_stopped'] },
    { status: 'maintenance', reasons: ['maintenance_mode'] }, { status: 'insufficient-data', reasons: [] }]) {
    journal.record(observation, start + 1000);
    const status = checkOperationsMonitor(f.config, start + 2000);
    assert.equal(status.status, 'fresh');
    assert.equal(status.lastSample?.status, observation.status);
  }
});

test('startup grace differs from sample cadence and never declares an unsampled collector healthy', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  assert.equal(checkOperationsMonitor(f.config, start + 10300).status, 'starting');
  const expired = checkOperationsMonitor(f.config, start + 10301);
  assert.equal(expired.exitCode, 2);
  assert.deepEqual(expired.reasons, ['startup_overdue']);
  assert.equal(expired.lastSample, null);
});

test('sample expires only after interval plus all three probe deadlines and scheduling allowance', t => {
  const f = fixture(t);
  f.check.timeoutMs = 30000;
  writeFileSync(f.config.checkConfigFile, JSON.stringify(f.check));
  const journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  assert.equal(checkOperationsMonitor(f.config, start + 130000).status, 'fresh');
  const status = checkOperationsMonitor(f.config, start + 130001);
  assert.equal(status.status, 'stale');
  assert.deepEqual(status.reasons, ['sample_overdue']);
  assert.equal(status.deadlineMs, 130000);
});

test('normal stop is not fresh even with a recent good sample and an unreleased lock', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  journal.lifecycle('collector_stopped', start + 1);
  assert.equal(checkOperationsMonitor(f.config, start + 2).status, 'stopped');
  journal.close();
  assert.equal(checkOperationsMonitor(f.config, start + 2).exitCode, 2);
});

test('missing lock and mismatched run or PID never reuse a recent good sample', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  const original = JSON.parse(readFileSync(f.lockPath, 'utf8'));
  unlinkSync(f.lockPath);
  assert.deepEqual(checkOperationsMonitor(f.config, start).reasons, ['lock_missing']);
  for (const change of [{ runId: randomUUID() }, { pid: original.pid + 1 }]) {
    writeFileSync(f.lockPath, JSON.stringify({ ...original, ...change }));
    assert.deepEqual(checkOperationsMonitor(f.config, start).reasons, ['identity_mismatch']);
  }
});

test('restart discards old-run sample evidence and starts a new first-sample grace period', t => {
  const f = fixture(t);
  let journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  journal.close();
  journal = f.open();
  assert.deepEqual(checkOperationsMonitor(f.config, start + 1).reasons, ['identity_mismatch']);
  journal.lifecycle('collector_started', start + 1);
  const status = checkOperationsMonitor(f.config, start + 2);
  assert.equal(status.status, 'starting');
  assert.equal(status.lastSample, null);
});

test('future records and clock rollback fail closed until a new collection run', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start + 1000);
  assert.deepEqual(checkOperationsMonitor(f.config, start + 999).reasons, ['clock_invalid']);
  journal.record(good, start + 500);
  assert.deepEqual(checkOperationsMonitor(f.config, start + 2000).reasons, ['clock_invalid']);
  journal.record(good, start + 2001);
  assert.deepEqual(checkOperationsMonitor(f.config, start + 2002).reasons, ['clock_invalid']);
});

test('wall clock is captured after the bounded file snapshot to avoid false future timestamps during publication', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start + 1);
  const original = readFileSync(f.receiptPath);
  // A clock read before the file snapshot would consume this replaced, deliberately invalid evidence.
  const clock = t.mock.method(Date, 'now', () => {
    writeFileSync(f.receiptPath, 'replacement-after-snapshot');
    return start + 2;
  });
  try {
    assert.equal(checkOperationsMonitor(f.config).status, 'fresh');
    assert.equal(clock.mock.callCount(), 1);
  } finally { clock.mock.restore(); writeFileSync(f.receiptPath, original); }
});

test('receipt validation rejects oversized, malformed, unexpected and incoherent evidence without echoing it', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  const valid = f.receipt();
  for (const value of ['private-invalid', 'a'.repeat(4097), JSON.stringify({ ...valid, version: 2 }),
    JSON.stringify({ ...valid, sample: { ...valid.sample, reasons: ['private-reason'] } }),
    JSON.stringify({ ...valid, private: 'private-extra' }),
    JSON.stringify({ ...valid, sample: null }),
    JSON.stringify({ ...valid, sample: { ...valid.sample, seq: valid.seq + 1 } }),
    JSON.stringify({ ...valid, startedAt: new Date(start + 1).toISOString() })]) {
    writeFileSync(f.receiptPath, value);
    const result = checkOperationsMonitor(f.config, start + 10);
    assert.equal(result.exitCode, 1);
    assert.doesNotMatch(JSON.stringify(result), /private-|journal|\.json/);
  }
});

test('status refuses missing legacy receipts, bad locks, unknown files and absent journal', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  const original = readFileSync(f.receiptPath);
  unlinkSync(f.receiptPath);
  assert.equal(checkOperationsMonitor(f.config, start).exitCode, 1);
  assert(!existsSync(f.receiptPath));
  writeFileSync(f.receiptPath, original);
  const lock = readFileSync(f.lockPath);
  writeFileSync(f.lockPath, 'bad-private-lock');
  assert.equal(checkOperationsMonitor(f.config, start).exitCode, 1);
  writeFileSync(f.lockPath, lock);
  const unrelated = join(f.config.directory, 'unrelated.txt');
  writeFileSync(unrelated, 'keep');
  assert.equal(checkOperationsMonitor(f.config, start).exitCode, 1);
  assert.equal(readFileSync(unrelated, 'utf8'), 'keep');
  unlinkSync(unrelated);
  journal.close();
  unlinkSync(join(f.config.directory, 'monitor.sqlite'));
  assert.equal(checkOperationsMonitor(f.config, start).exitCode, 1);
});

test('fingerprint detects live changes to HTTP timeout, target, thresholds and cadence', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  for (const patch of [{ timeoutMs: 200 }, { baseUrl: 'http://127.0.0.1:2' },
    { thresholds: { ...f.check.thresholds, minimumRequests: 2 } }]) {
    writeFileSync(f.config.checkConfigFile, JSON.stringify({ ...f.check, ...patch }));
    assert.deepEqual(checkOperationsMonitor(f.config, start).reasons, ['configuration_changed']);
  }
  writeFileSync(f.config.checkConfigFile, JSON.stringify(f.check));
  for (const patch of [{ intervalSeconds: 31 }, { failureSamples: 1 }, { recoverySamples: 1 }]) {
    assert.deepEqual(checkOperationsMonitor({ ...f.config, ...patch }, start).reasons, ['configuration_changed']);
  }
  assert.equal(checkOperationsMonitor({ ...f.config, retentionEvents: 200 }, start).status, 'fresh');
});

test('status never creates directories, acquires locks or changes live and stopped journal files', t => {
  const f = fixture(t);
  assert.equal(checkOperationsMonitor(f.config, start).exitCode, 1);
  assert(!existsSync(f.config.directory));
  const journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  const live = digest(f.config.directory);
  assert.equal(checkOperationsMonitor(f.config, start).status, 'fresh');
  assert.deepEqual(digest(f.config.directory), live);
  journal.lifecycle('collector_stopped', start);
  journal.close();
  const stopped = digest(f.config.directory);
  assert.equal(checkOperationsMonitor(f.config, start).status, 'stopped');
  assert.deepEqual(digest(f.config.directory), stopped);
  assert(!existsSync(join(f.config.directory, 'monitor.sqlite-wal')));
  assert(!existsSync(f.lockPath));
});

test('rolled back samples cannot advance the public receipt', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  const before = readFileSync(f.receiptPath);
  const db = new DatabaseSync(join(f.config.directory, 'monitor.sqlite'));
  try {
    db.exec("CREATE TRIGGER fail_status BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'test'); END");
    assert.throws(() => journal.record(failed, start + 1));
    assert.deepEqual(readFileSync(f.receiptPath), before);
  } finally { db.close(); }
});

test('publication failure leaves the last complete receipt and does not roll back a committed sample', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  journal.record(good, start);
  const before = readFileSync(f.receiptPath);
  writeFileSync(join(f.config.directory, 'collector-status.pending'), 'interrupted');
  assert.throws(() => journal.record(failed, start + 1));
  assert.deepEqual(readFileSync(f.receiptPath), before);
  const db = new DatabaseSync(join(f.config.directory, 'monitor.sqlite'), { readOnly: true });
  try { assert.equal(db.prepare("SELECT COUNT(*) AS n FROM events WHERE event='sample'").get()!.n, 2); }
  finally { db.close(); }
  journal.close();
  assert.deepEqual(checkOperationsMonitor(f.config, start + 2).reasons, ['lock_missing']);
  const restarted = f.open();
  restarted.lifecycle('collector_started', start + 2);
  assert(!existsSync(join(f.config.directory, 'collector-status.pending')));
  assert.equal(checkOperationsMonitor(f.config, start + 3).status, 'starting');
});

test('event retention and incident transitions preserve the latest sample receipt', t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started', start);
  for (let i = 0; i < 160; i++) journal.record(failed, start + i);
  const result = checkOperationsMonitor(f.config, start + 160);
  assert.equal(result.status, 'fresh');
  assert.equal(result.lastSample?.status, 'unavailable');
  assert.equal(f.receipt().event, 'sample');
});

test('independent status CLI uses exit codes and never outputs configuration or credentials', async t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started');
  const starting = await cli([f.configFile]);
  assert.equal(starting.code, 3, starting.stdout + starting.stderr);
  journal.record(good);
  const fresh = await cli([f.configFile]);
  assert.equal(fresh.code, 0, fresh.stdout + fresh.stderr);
  journal.lifecycle('collector_stopped'); journal.close();
  const stopped = await cli([f.configFile]);
  assert.equal(stopped.code, 2, stopped.stdout + stopped.stderr);
  writeFileSync(f.configFile, 'private-config-and-credential');
  const bad = await cli([f.configFile]);
  const extra = await cli([f.configFile, '--extra']);
  assert.equal(bad.code, 1);
  assert.equal(extra.code, 1);
  for (const result of [starting, fresh, stopped, bad, extra]) {
    assert.doesNotMatch(result.stdout + result.stderr, /ops_v1_|private-|monitor\.json|absent-token|127\.0\.0\.1/);
    assert.equal(JSON.parse(result.stdout).exitCode, result.code);
  }
});

test('killed collector with a leftover lock becomes stale in an independent CLI after the real deadline', { timeout: 65000 }, async t => {
  const f = fixture(t);
  const server = createServer((_req, res) => { res.end(JSON.stringify({ code: 10000, data: { mode: 'maintenance' } })); });
  server.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const address = server.address(); assert(address && typeof address !== 'string');
  writeFileSync(f.check.tokenFile, JSON.stringify({ token: 'ops_v1_' + 'a'.repeat(64) }));
  writeFileSync(f.config.checkConfigFile, JSON.stringify({ ...f.check, baseUrl: `http://127.0.0.1:${address.port}` }));
  const child = spawn(process.execPath, ['--import', 'tsx', 'tool/operations-monitor.ts', f.configFile],
    { cwd: serverRoot, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  const closed = new Promise<void>(resolve => child.once('close', () => resolve()));
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); await closed; });
  await new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Collector did not sample')), 10000);
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.stdout.on('data', data => {
      output += String(data);
      if (output.includes('"event":"sample"')) { clearTimeout(timeout); resolve(); }
    });
  });
  const running = await cli([f.configFile]);
  assert.equal(running.code, 0, running.stdout + running.stderr);
  assert.equal(JSON.parse(running.stdout).lastSample.status, 'maintenance');
  child.kill('SIGKILL'); await closed;
  assert(existsSync(f.lockPath));
  const sampleAt = Date.parse(f.receipt().sample!.at);
  const before = digest(f.config.directory);
  await delay(Math.max(0, sampleAt + 40301 - Date.now()) + 150);
  const stale = await cli([f.configFile]);
  assert.equal(stale.code, 2, stale.stdout + stale.stderr);
  assert.equal(JSON.parse(stale.stdout).status, 'stale');
  assert.deepEqual(JSON.parse(stale.stdout).reasons, ['sample_overdue']);
  assert.deepEqual(digest(f.config.directory), before);
  assert.doesNotMatch(output + stale.stdout + stale.stderr, /ops_v1_|absent-token|127\.0\.0\.1/);
});
