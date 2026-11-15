import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { request } from 'node:http';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';
import { AuthService } from '../../src/auth.js';
import { createOperationsKey } from '../../src/operations-key.js';
import { operationsKeyringSchema, readOperationsKeyring } from '../../src/operations-credentials.js';
import { readOperationsToken, runOperationsCheck, type OperationsCheckConfig } from '../../src/operations-check.js';

const first = 'ops_v1_' + 'a'.repeat(64);
const second = 'ops_v1_' + 'b'.repeat(64);
const clockStart = Date.parse('2026-10-29T00:00:00Z');
const key = (token: string, id = 'initial', start = clockStart, end = clockStart + 86400000) => ({
  id, sha256: createHash('sha256').update(token).digest('hex'),
  notBefore: new Date(start).toISOString(), expiresAt: new Date(end).toISOString(),
});

function temporary(t: TestContext) {
  const directory = mkdtempSync(join(tmpdir(), 'haven-operations-key-'));
  t.after(() => {
    assert.equal(dirname(directory), tmpdir());
    assert(basename(directory).startsWith('haven-operations-key-'));
    rmSync(directory, { recursive: true, force: true });
  });
  return directory;
}

async function fixture(t: TestContext, enabled = true) {
  const directory = temporary(t);
  const path = join(directory, 'keys.json');
  writeFileSync(path, JSON.stringify({ version: 1, keys: [key(first)] }));
  let now = clockStart;
  const logs: object[] = [];
  const config = readConfig({ DATABASE_PATH: ':memory:', CLIENT_MIN_VERSION: '9.0.0',
    OPERATIONS_KEYS_FILE: enabled ? path : '' });
  const { app, store, notifications } = createApp(config, { now: () => now, pushTimer: false, log: event => logs.push(event) });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await notifications.stop(); store.close();
  });
  const auth = new AuthService(store, () => now);
  const { code } = await auth.sendCode('13800138000');
  const admin = auth.login({ mobile: '13800138000', code });
  store.run("UPDATE users SET role='admin'");
  async function call(token: string | undefined = first, path = '/operations/snapshot', method = 'GET', extra: Record<string, string> = {}) {
    return fetch(base + path, { method, headers: { 'X-Operations-Version': '1', 'X-Client-Version': '9.0.0',
      'X-Client-Platform': 'admin-web', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...extra } });
  }
  return { base, path, directory, store, logs, admin, call, at: (value: number) => { now = value; } };
}

test('machine metrics are disabled by default, even with a valid administrator session', async t => {
  const f = await fixture(t, false);
  assert.equal((await f.call()).status, 404);
  assert.equal((await f.call(f.admin.token)).status, 404);
  assert.equal((await f.call(first, '/operations/snapshot', 'POST')).status, 404);
  assert.equal((await f.call(f.admin.token, '/management/operations')).status, 200);
});

test('read-only key survives user session expiry and cannot authenticate business, media or refresh routes', async t => {
  const f = await fixture(t);
  f.at(clockStart + 31 * 60000);
  const response = await f.call(first, '/operations/snapshot', 'GET', { 'X-Client-Version': '1.0.0' });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal((await response.json() as any).data.schemaVersion, 1);
  assert.equal((await f.call(f.admin.token, '/management/operations')).status, 401);
  for (const [path, method] of [['/management/operations', 'GET'], ['/management/workers', 'POST'],
    ['/userInfo', 'GET'], ['/room', 'POST'], ['/media/' + 'c'.repeat(64), 'GET'], ['/refreshToken', 'POST']]) {
    assert.equal((await f.call(first, path, method)).status, 401, path);
  }
  assert.equal((await f.call(first.slice(7), '/userInfo')).status, 401);
  assert.equal((await f.call(key(first).sha256, '/userInfo')).status, 401);
});

test('machine endpoint rejects user tokens, malformed credentials, future keys and expired keys at exact boundaries', async t => {
  const f = await fixture(t);
  for (const credential of [undefined, f.admin.token, first.slice(7), key(first).sha256, 'ops_v1_short', second]) {
    const response = await f.call(credential === undefined ? '' : credential);
    assert.equal(response.status, 401);
    assert.equal((await response.json() as any).data, null);
  }
  f.at(clockStart - 1);
  assert.equal((await f.call()).status, 401);
  f.at(clockStart);
  assert.equal((await f.call()).status, 200);
  f.at(clockStart + 86400000 - 1);
  assert.equal((await f.call()).status, 200);
  f.at(clockStart + 86400000);
  assert.equal((await f.call()).status, 401);
  assert.doesNotMatch(JSON.stringify(f.logs), /ops_v1_|aaaaaaaa|bbbbbbbb/);
});

test('protocol and method gate reject unsupported monitoring clients without changing app version policy', async t => {
  const f = await fixture(t);
  for (const version of ['', '0', '2', '1, 1']) assert.equal((await f.call(first, '/operations/snapshot', 'GET', { 'X-Operations-Version': version })).status, 426);
  for (const method of ['POST', 'PUT', 'DELETE', 'HEAD']) {
    const response = await f.call(first, '/operations/snapshot', method);
    assert.equal(response.status, 405);
    assert.equal(response.headers.get('allow'), 'GET');
  }
  assert.equal((await f.call(first, '/operations/snapshot', 'GET', { 'X-Client-Version': '0.0.0' })).status, 200);
  assert.equal((await f.call(f.admin.token, '/management/operations', 'GET', { 'X-Client-Version': '0.0.0' })).status, 426);
});

test('rotation accepts two keys and immediately revokes removed keys without restart or last-good fallback', async t => {
  const f = await fixture(t);
  const save = (keys: ReturnType<typeof key>[]) => writeFileSync(f.path, JSON.stringify({ version: 1, keys }));
  assert.equal((await f.call()).status, 200);
  save([key(first), key(second, 'replacement')]);
  assert.equal((await f.call(first)).status, 200);
  assert.equal((await f.call(second)).status, 200);
  save([key(second, 'replacement')]);
  assert.equal((await f.call(first)).status, 401);
  assert.equal((await f.call(second)).status, 200);
  writeFileSync(f.path, '{"private-broken-data"');
  const broken = await f.call(second);
  assert.equal(broken.status, 503);
  assert.doesNotMatch(await broken.text(), /private-broken|keys\.json|ops_v1_/);
  save([]);
  assert.equal((await f.call(second)).status, 401);
  unlinkSync(f.path);
  assert.equal((await f.call(second)).status, 503);
  save([key(second, 'replacement')]);
  assert.equal((await f.call(second)).status, 200);
});

test('invalid requests consume machine polling budget and duplicate authorization headers are rejected', async t => {
  const f = await fixture(t);
  const duplicateStatus = await new Promise<number | undefined>((resolve, reject) => {
    const req = request(f.base + '/operations/snapshot', { headers: ['Host', new URL(f.base).host, 'X-Operations-Version', '1',
      'Authorization', `Bearer ${first}`, 'Authorization', `Bearer ${second}`] }, response => {
      response.resume(); response.on('end', () => resolve(response.statusCode));
    });
    req.on('error', reject); req.end();
  });
  assert.equal(duplicateStatus, 401);
  for (let i = 0; i < 11; i++) assert.equal((await f.call(second)).status, 401);
  assert.equal((await f.call(first)).status, 429);
  // The separate administrator quota still works.
  assert.equal((await f.call(f.admin.token, '/management/operations')).status, 200);
});

test('invalid keyring config stops startup before opening a database and never echoes its contents', t => {
  const directory = temporary(t);
  const path = join(directory, 'keys.json');
  const database = join(directory, 'not-created.sqlite');
  for (const raw of ['private-secret', JSON.stringify({ version: 1, keys: [key(first), key(second)] }),
    JSON.stringify({ version: 1, keys: [key(first), key(second, 'next'), key('ops_v1_' + 'c'.repeat(64), 'third')] }),
    JSON.stringify({ version: 1, keys: [{ ...key(first), token: first }] }), 'x'.repeat(4097)]) {
    writeFileSync(path, raw);
    assert.throws(() => createApp(readConfig({ OPERATIONS_KEYS_FILE: path, DATABASE_PATH: database })), error => {
      assert.equal((error as Error).message, 'OPERATIONS_KEYS_FILE 无法读取或格式不正确'); return true;
    });
    assert.equal(existsSync(database), false);
  }
  assert.throws(() => readConfig({ OPERATIONS_KEYS_FILE: 'relative/keys.json' }), /必须是绝对路径/);
  assert.equal(operationsKeyringSchema.safeParse({ version: 1, keys: [key(first), { ...key(first), id: 'duplicate-digest' }] }).success, false);
  assert.equal(operationsKeyringSchema.safeParse({ version: 1, keys: [key(first, 'bad', clockStart, clockStart)] }).success, false);
});

test('generator creates a restricted directory with only a token and digest keyring and never overwrites', t => {
  const directory = temporary(t);
  const target = join(directory, 'new-key');
  const report = createOperationsKey(target, new Date(clockStart + 86400000).toISOString(), clockStart);
  assert.deepEqual(readdirSync(target).sort(), ['keys.json', 'token.json']);
  const token = readOperationsToken(join(target, 'token.json'));
  const ring = readOperationsKeyring(join(target, 'keys.json'));
  assert.match(token, /^ops_v1_[a-f0-9]{64}$/);
  assert.equal(ring.keys[0]!.sha256, createHash('sha256').update(token).digest('hex'));
  assert.equal(report.id, ring.keys[0]!.id);
  assert(!JSON.stringify(report).includes(token));
  assert(!JSON.stringify(ring).includes(token));
  const saved = readFileSync(join(target, 'token.json'), 'utf8');
  assert.throws(() => createOperationsKey(target, new Date(clockStart + 86400000).toISOString(), clockStart));
  assert.equal(readFileSync(join(target, 'token.json'), 'utf8'), saved);
  assert.throws(() => createOperationsKey(join(directory, 'expired'), new Date(clockStart).toISOString(), clockStart));
  assert.equal(existsSync(join(directory, 'expired')), false);
  assert.throws(() => createOperationsKey('relative', new Date(clockStart + 86400000).toISOString(), clockStart));
  if (process.platform === 'win32') {
    // Verify the actual ACL, not merely the icacls exit status; SID output avoids localized names.
    const script = join(directory, 'verify-acl.ps1');
    writeFileSync(script, '$acl = Get-Acl -LiteralPath $args[0]\n' +
      '$rules = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value })\n' +
      '[pscustomobject]@{ protected=$acl.AreAccessRulesProtected; rules=$rules; current=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } | ConvertTo-Json -Compress\n');
    const acl = JSON.parse(execFileSync('pwsh', ['-NoProfile', '-File', script, target], { encoding: 'utf8', windowsHide: true }));
    assert.equal(acl.protected, true);
    assert.deepEqual(acl.rules.sort(), [acl.current, 'S-1-5-18'].sort());
  } else {
    assert.equal(statSync(target).mode & 0o777, 0o700);
    assert.equal(statSync(join(target, 'token.json')).mode & 0o777, 0o600);
  }
});

function checkConfig(baseUrl: string, tokenFile: string): OperationsCheckConfig {
  return { baseUrl, tokenFile, authentication: 'operations-key', clientVersion: '1.0.0', timeoutMs: 5000,
    thresholds: { minimumRequests: 1, maxServerErrorRate: 0, maxAuthRejected: 0, maxAborted: 0, maxP95Ms: 10000,
      maxDue: 0, maxDueDelayMs: 0, maxStopped: 0, maxExpiredLeases: 0, maxUnconfigured: 0, maxBackgroundFailures: 0 } };
}

test('machine check does not need a live admin session and does not downgrade to administrator authentication', async t => {
  const f = await fixture(t);
  f.at(clockStart + 31 * 60000);
  const settings = checkConfig(f.base, 'unused');
  const result = await runOperationsCheck(settings, first);
  assert.equal(result.status, 'insufficient-data');
  assert.equal(result.exitCode, 3);
  assert.equal((await runOperationsCheck(settings, f.admin.token)).status, 'unavailable');
  assert.equal((await runOperationsCheck({ ...settings, authentication: 'admin-session' }, first)).status, 'unavailable');
  writeFileSync(f.path, JSON.stringify({ version: 1, keys: [] }));
  assert.equal((await runOperationsCheck(settings, first)).status, 'unavailable');
});

test('real key generator and check CLIs keep secrets out of stdout and retain protocol exit codes', async t => {
  const directory = temporary(t);
  const target = join(directory, 'generated');
  const run = (tool: string, args: string[]) => new Promise<{ code: number | null; output: string }>((resolve, reject) => {
    const child = spawn(process.execPath, ['--import', 'tsx', `tool/${tool}.ts`, ...args],
      { cwd: fileURLToPath(new URL('../../', import.meta.url)), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    child.stdout.on('data', value => { output += String(value); });
    child.stderr.on('data', value => { output += String(value); });
    child.on('error', reject); child.on('close', code => resolve({ code, output }));
  });
  const generated = await run('operations-key', [target, new Date(Date.now() + 86400000).toISOString()]);
  assert.equal(generated.code, 0, generated.output);
  const token = readOperationsToken(join(target, 'token.json'));
  assert(!generated.output.includes(token));
  assert(!generated.output.includes(createHash('sha256').update(token).digest('hex')));
  const denied = await run('operations-key', [target, new Date(Date.now() + 86400000).toISOString()]);
  assert.equal(denied.code, 1);
  assert.equal(readOperationsToken(join(target, 'token.json')), token);
  const { app, store, notifications } = createApp(readConfig({ DATABASE_PATH: ':memory:',
    OPERATIONS_KEYS_FILE: join(target, 'keys.json') }), { pushTimer: false, log: () => {} });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  t.after(async () => { await new Promise<void>(resolve => server.close(() => resolve())); await notifications.stop(); store.close(); });
  const address = server.address(); assert(address && typeof address !== 'string');
  const path = join(directory, 'check.json');
  writeFileSync(path, JSON.stringify(checkConfig(`http://127.0.0.1:${address.port}`, join(target, 'token.json'))));
  const checked = await run('operations-check', [path]);
  assert.equal(checked.code, 3, checked.output);
  assert.match(checked.output, /insufficient-data/);
  assert(!checked.output.includes(token));
});
