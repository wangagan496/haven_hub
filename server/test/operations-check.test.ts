import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type RequestListener } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { TestContext } from 'node:test';
import { createMaintenanceApp } from '../src/maintenance.js';
import { readConfig } from '../src/config.js';
import { OperationsMetrics } from '../src/operations.js';
import { operationsCheckConfigSchema, readOperationsCheckConfig, readOperationsToken, runOperationsCheck,
  type OperationsCheckConfig } from '../src/operations-check.js';
import { fixture } from './repair-fixture.js';

const token = 'a'.repeat(64);
function config(baseUrl: string): OperationsCheckConfig {
  return { baseUrl, tokenFile: 'unused', clientVersion: '1.0.0', timeoutMs: 5000,
    thresholds: { minimumRequests: 1, maxServerErrorRate: 0, maxAuthRejected: 0, maxAborted: 0, maxP95Ms: 10000,
      maxDue: 0, maxDueDelayMs: 0, maxStopped: 0, maxExpiredLeases: 0, maxUnconfigured: 0, maxBackgroundFailures: 0 } };
}

async function listen(t: TestContext, listener: RequestListener) {
  const server = createServer(listener).listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const address = server.address();
  assert(address && typeof address !== 'string');
  return { server, base: `http://127.0.0.1:${address.port}` };
}

function emptySnapshot() {
  return { schemaVersion: 1, generatedAt: 1000, requests: new OperationsMetrics(() => 0).snapshot(),
    push: { activeDeliveries: 0, queued: 0, failed: 0, sending: 0, accepted: 0, unconfigured: 0,
      expired: 0, unknownStatus: 0, stopped: 0, expiredLeases: 0, orphaned: 0, due: 0, oldestDueDelayMs: null as number | null } };
}

test('local operations check detects an injected server error and auth rejection through real HTTP', async t => {
  const f = await fixture(t);
  const settings = config(f.base);
  assert.equal((await runOperationsCheck(settings, f.tokens.admin)).status, 'ok');
  const original = f.store.one;
  f.store.one = function (sql, ...values) {
    if (sql.startsWith('SELECT id, nickName, avatar, role FROM users')) throw new Error('private failure');
    return original.call(this, sql, ...values);
  };
  assert.equal((await f.raw('resident', 'GET', '/userInfo')).status, 500);
  f.store.one = original;
  await f.raw(undefined, 'POST', '/login', {});
  const report = await runOperationsCheck(settings, f.tokens.admin);
  assert.equal(report.status, 'alert');
  assert.equal(report.exitCode, 2);
  assert(report.reasons.includes('server_error_rate'));
  assert(report.reasons.includes('auth_rejected'));
  assert(!JSON.stringify(report).includes(f.tokens.admin));
  assert(!JSON.stringify(report).includes('private failure'));
});

test('empty business window is insufficient data; failures during warmup still alert', async t => {
  const snapshot = emptySnapshot();
  const { base } = await listen(t, (req, res) => res.end(JSON.stringify({ code: 10000, data:
    req.url === '/health' ? { mode: 'local-learning' } : req.url === '/ready' ? { ready: true } : snapshot })));
  assert.equal((await runOperationsCheck(config(base), token)).status, 'insufficient-data');
  snapshot.requests.smsSendFailures = 1;
  snapshot.push.due = 1;
  snapshot.push.oldestDueDelayMs = 1;
  snapshot.push.stopped = 1;
  snapshot.push.expiredLeases = 1;
  snapshot.push.unconfigured = 1;
  snapshot.push.orphaned = 1;
  snapshot.requests.aborted = 1;
  const report = await runOperationsCheck(config(base), token);
  assert.equal(report.exitCode, 2);
  assert.deepEqual(report.reasons.sort(), ['background_failures', 'push_due', 'push_expired_leases',
    'push_invalid_state', 'push_overdue', 'push_stopped', 'push_unconfigured', 'requests_aborted'].sort());
});

test('threshold boundary, percentile overflow and low sample ratio are handled explicitly', async t => {
  const snapshot = emptySnapshot();
  snapshot.requests.completed = 20;
  snapshot.requests.serverErrors = 1;
  snapshot.requests.serverErrorRate = 0.05;
  snapshot.requests.latency.p95UpperBoundMs = 1000;
  const { base } = await listen(t, (req, res) => res.end(JSON.stringify({ code: 10000, data:
    req.url === '/health' ? { mode: 'production' } : req.url === '/ready' ? { ready: true } : snapshot })));
  const settings = config(base);
  settings.thresholds.minimumRequests = 20;
  settings.thresholds.maxServerErrorRate = 0.05;
  settings.thresholds.maxP95Ms = 1000;
  assert.equal((await runOperationsCheck(settings, token)).status, 'ok');
  snapshot.requests.latency.p95UpperBoundMs = null;
  assert((await runOperationsCheck(settings, token)).reasons.includes('request_latency'));
  snapshot.requests.completed = 19;
  assert.equal((await runOperationsCheck(settings, token)).status, 'insufficient-data');
});

test('maintenance mode is not ready or healthy business and does not request a snapshot', async t => {
  const app = createMaintenanceApp(readConfig({ MAINTENANCE_MODE: 'true' }));
  const { base } = await listen(t, app);
  const result = await runOperationsCheck(config(base), token);
  assert.deepEqual(result, { status: 'maintenance', reasons: ['maintenance_mode'], exitCode: 3 });
});

test('expired, resident and missing credentials never obtain operational data', async t => {
  const f = await fixture(t);
  for (const credential of [f.tokens.resident, token, '', `${token}\r\nInjected: value`]) {
    const report = await runOperationsCheck(config(f.base), credential);
    assert.deepEqual(report, { status: 'unavailable', reasons: ['probe_failed'], exitCode: 1 });
  }
});

test('a failed readiness probe stops before the credential-bearing snapshot request', async t => {
  let credentials = 0;
  const { base } = await listen(t, (req, res) => {
    if (req.headers.authorization) credentials++;
    if (req.url === '/health') res.end(JSON.stringify({ code: 10000, data: { mode: 'production' } }));
    else { res.statusCode = 503; res.end('private internal failure'); }
  });
  assert.equal((await runOperationsCheck(config(base), token)).status, 'unavailable');
  assert.equal(credentials, 0);
});

test('probes refuse redirects, wrong schema and oversized bodies without echoing server input', async t => {
  let mode = 'redirect';
  let redirected = 0;
  const { base } = await listen(t, (req, res) => {
    if (req.url === '/target') redirected++;
    if (mode === 'redirect') { res.writeHead(302, { Location: '/target?secret=private' }); res.end(); }
    else if (mode === 'oversized') res.end('private'.repeat(5000));
    else res.end(JSON.stringify({ code: 10000, data: { mode: 'production', ready: true, secret: 'private' } }));
  });
  for (mode of ['redirect', 'oversized', 'wrong-schema']) {
    const report = await runOperationsCheck(config(base), token);
    assert.equal(report.status, 'unavailable');
    assert.doesNotMatch(JSON.stringify(report), /private|target|secret/);
  }
  assert.equal(redirected, 0);
});

test('timeout covers a response body that never completes, and closed server is unavailable', async t => {
  const { server, base } = await listen(t, (_req, res) => { res.writeHead(200); res.write('{'); });
  const settings = { ...config(base), timeoutMs: 100 };
  const started = performance.now();
  assert.equal((await runOperationsCheck(settings, token)).exitCode, 1);
  assert(performance.now() - started < 2500);
  await new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); });
  assert.equal((await runOperationsCheck(settings, token)).status, 'unavailable');
});

test('credential-bearing probe refuses a redirect instead of forwarding the administrator session', async t => {
  let sinkHits = 0;
  const sink = await listen(t, (_req, res) => { sinkHits++; res.end('{}'); });
  const { base } = await listen(t, (req, res) => {
    if (req.url === '/management/operations') {
      assert.equal(req.headers.authorization, `Bearer ${token}`);
      res.writeHead(302, { Location: sink.base }); res.end();
    } else res.end(JSON.stringify({ code: 10000, data: req.url === '/health' ? { mode: 'production' } : { ready: true } }));
  });
  assert.equal((await runOperationsCheck(config(base), token)).status, 'unavailable');
  assert.equal(sinkHits, 0);
});

test('check config rejects external targets, missing thresholds and invalid versions', () => {
  for (const base of ['https://example.com', 'http://localhost:3000', 'http://127.0.0.1.evil.test',
    'http://user:pass@127.0.0.1', 'file:///tmp/data', 'http://127.0.0.1/path', 'http://127.0.0.1?secret=x']) {
    assert.equal(operationsCheckConfigSchema.safeParse(config(base)).success, false);
  }
  assert.equal(operationsCheckConfigSchema.safeParse(config('http://[::1]:3000')).success, true);
  assert.equal(operationsCheckConfigSchema.safeParse({ ...config('http://127.0.0.1'), thresholds: {} }).success, false);
  assert.equal(operationsCheckConfigSchema.safeParse({ ...config('http://127.0.0.1'), clientVersion: 'latest' }).success, false);
});

test('CLI uses a separate credential file, returns real exit codes and redacts invalid local input', async t => {
  const f = await fixture(t);
  const directory = mkdtempSync(join(tmpdir(), 'haven-operations-check-'));
  t.after(() => {
    assert.equal(dirname(directory), tmpdir());
    assert(basename(directory).startsWith('haven-operations-check-'));
    rmSync(directory, { recursive: true, force: true });
  });
  const path = join(directory, 'config.json');
  const tokenPath = join(directory, 'session.json');
  const settings = { ...config(f.base), tokenFile: 'session.json' };
  writeFileSync(path, JSON.stringify(settings));
  writeFileSync(tokenPath, JSON.stringify({ token: f.tokens.admin }), { mode: 0o600 });
  assert.equal(readOperationsCheckConfig(path).tokenFile, tokenPath);
  assert.equal(readOperationsToken(tokenPath), f.tokens.admin);
  async function run() {
    return new Promise<{ code: number | null; output: string }>((resolve, reject) => {
      const child = spawn(process.execPath, ['--import', 'tsx', 'tool/operations-check.ts', path],
        { cwd: fileURLToPath(new URL('../', import.meta.url)), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
      let output = '';
      child.stdout.on('data', chunk => { output += String(chunk); });
      child.stderr.on('data', chunk => { output += String(chunk); });
      child.on('error', reject);
      child.on('close', code => resolve({ code, output }));
    });
  }
  const healthy = await run();
  assert.equal(healthy.code, 0, healthy.output);
  assert.equal(JSON.parse(healthy.output).status, 'ok');
  await f.raw(undefined, 'POST', '/login', {});
  const alert = await run();
  assert.equal(alert.code, 2, alert.output);
  writeFileSync(tokenPath, JSON.stringify({ token: 'private-secret-not-a-token' }));
  assert.throws(() => readOperationsToken(tokenPath), /^Error: 运行检查凭证文件无效$/);
  const invalid = await run();
  assert.equal(invalid.code, 1);
  assert.doesNotMatch(healthy.output + alert.output + invalid.output, /private-secret|session\.json/);
  assert(!(healthy.output + alert.output).includes(f.tokens.admin));
});
