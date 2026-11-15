import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { fork, spawnSync } from 'node:child_process';
import { dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { AuthService, type AuthOptions } from '../../src/auth.js';
import { Store } from '../../src/database.js';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';
import { SmsDeliveryError } from '../../src/sms.js';
import { accepted, productionEnv, smsConfig } from './sms-fixture.js';

const mobile = '13800138000';
const start = Date.UTC(2026, 9, 29);
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
function fixture(t: TestContext, overrides: Partial<Extract<AuthOptions, { mode: 'tencent' }>> = {}) {
  const store = new Store(':memory:');
  t.after(() => store.close());
  let now = start;
  const sent: { mobile: string; code: string }[] = [];
  const options: AuthOptions = { mode: 'tencent', hourlyLimit: 5, dailyLimit: 10, globalDailyLimit: 100,
    sender: async (mobile, code) => { assert.equal(store.isInTransaction, false); sent.push({ mobile, code }); }, ...overrides };
  const auth = new AuthService(store, () => now, options);
  return { store, auth, sent, options, time: () => now, advance: (ms: number) => { now += ms; } };
}

test('real SMS only returns a receipt, stores a hash and consumes the code once', async t => {
  const f = fixture(t);
  assert.deepEqual(await f.auth.sendCode(mobile), { development: false, expiresIn: 300 });
  const code = f.sent[0]!.code;
  assert.match(code, /^\d{6}$/);
  assert.equal(f.store.one('SELECT hash FROM codes WHERE mobile=?', mobile)!.hash, hash(`${mobile}:${code}`));
  const session = f.auth.login({ mobile, code });
  assert.equal(session.role, 'resident');
  assert.equal(f.store.one('SELECT nickName FROM users WHERE mobile=?', mobile)!.nickName, '住户');
  assert.doesNotThrow(() => f.auth.authenticate(`Bearer ${session.token}`));
  assert.throws(() => f.auth.login({ mobile, code }), /无效/);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM sessions')!.n, 1);
  await assert.rejects(f.auth.sendCode(mobile), /60秒/);
  const next = f.auth.refresh(`Bearer ${session.refreshToken}`);
  assert.throws(() => f.auth.authenticate(`Bearer ${session.token}`), /失效/);
  assert.throws(() => f.auth.refresh(`Bearer ${session.refreshToken}`), /失效/);
  assert.doesNotThrow(() => f.auth.authenticate(`Bearer ${next.token}`));
});

test('wrong attempts commit and lock at five; expiry at five minutes is exact', async t => {
  const f = fixture(t);
  await f.auth.sendCode(mobile);
  const code = f.sent[0]!.code;
  const wrong = code === '000000' ? '999999' : '000000';
  for (let attempt = 1; attempt <= 5; attempt++) {
    assert.throws(() => f.auth.login({ mobile, code: wrong }), /验证码错误/);
    assert.equal(f.store.one('SELECT attempts FROM codes')!.attempts, attempt);
  }
  assert.throws(() => f.auth.login({ mobile, code }), /无效/);
  f.advance(60_000);
  await f.auth.sendCode(mobile);
  f.advance(300_000);
  assert.throws(() => f.auth.login({ mobile, code: f.sent[1]!.code }), /过期/);
});

test('pending, failed and uncertain sends cannot log in, retain cooldown and consume budgets', async t => {
  let complete!: () => void;
  let code = '';
  const f = fixture(t, { globalDailyLimit: 1, sender: async (_mobile, value) => {
    code = value;
    await new Promise<void>(resolve => { complete = resolve; });
    throw new SmsDeliveryError('timeout');
  } });
  const pending = f.auth.sendCode(mobile);
  assert.throws(() => f.auth.login({ mobile, code }), /无效/);
  await assert.rejects(f.auth.sendCode(mobile), /60秒/);
  complete();
  await assert.rejects(pending, /发送未确认/);
  assert.throws(() => f.auth.login({ mobile, code }), /无效/);
  f.advance(60_000);
  await assert.rejects(f.auth.sendCode(mobile), /上限/);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM sms_send_attempts')!.n, 1);
});

test('late acceptance cannot overwrite a newer challenge', async t => {
  let complete!: () => void;
  const codes: string[] = [];
  const f = fixture(t, { sender: async (_mobile, code) => {
    codes.push(code);
    if (codes.length === 1) await new Promise<void>(resolve => { complete = resolve; });
  } });
  const old = f.auth.sendCode(mobile);
  f.advance(60_000);
  await f.auth.sendCode(mobile);
  complete();
  await assert.rejects(old, /请求已更新/);
  assert.doesNotThrow(() => f.auth.login({ mobile, code: codes[1] }));
});

test('disabling an account while SMS is pending prevents activation and subsequent sends', async t => {
  let complete!: () => void;
  const f = fixture(t, { sender: async () => new Promise<void>(resolve => { complete = resolve; }) });
  f.store.run('INSERT INTO users(id,mobile,nickName) VALUES (?,?,?)', 'worker', mobile, '测试');
  const pending = f.auth.sendCode(mobile);
  f.store.run('UPDATE users SET disabledAt=?', start);
  complete();
  await assert.rejects(pending, /停用/);
  assert.equal(f.store.one('SELECT expires FROM codes')!.expires, 0);
  await assert.rejects(f.auth.sendCode(mobile), /停用/);
});

test('rolling phone hourly and daily limits expire at their boundaries', async t => {
  const f = fixture(t, { hourlyLimit: 1, dailyLimit: 2 });
  await f.auth.sendCode(mobile);
  f.advance(60_000);
  await assert.rejects(f.auth.sendCode(mobile), /上限/);
  f.advance(3540_000);
  await f.auth.sendCode(mobile);
  f.advance(3600_000);
  await assert.rejects(f.auth.sendCode(mobile), /上限/);
  f.advance(22 * 3600_000);
  await f.auth.sendCode(mobile);
  assert.equal(f.sent.length, 3);
  assert.equal(f.store.one('SELECT COUNT(*) AS n FROM sms_send_attempts')!.n, 2);
});

test('mode changes never accept development OTPs, access or refresh tokens', async t => {
  const f = fixture(t);
  const dev = new AuthService(f.store, f.time);
  const first = (await dev.sendCode(mobile)).code;
  assert.throws(() => f.auth.login({ mobile, code: first }), /无效/);
  const session = dev.login({ mobile, code: first });
  assert.throws(() => f.auth.authenticate(`Bearer ${session.token}`), /失效/);
  assert.throws(() => f.auth.refresh(`Bearer ${session.refreshToken}`), /失效/);
  await f.auth.sendCode(mobile);
  assert.throws(() => dev.login({ mobile, code: f.sent[0]!.code }), /无效/);
  const real = f.auth.login({ mobile, code: f.sent[0]!.code });
  assert.throws(() => dev.authenticate(`Bearer ${real.token}`), /失效/);
  assert.throws(() => dev.refresh(`Bearer ${real.refreshToken}`), /失效/);
});

test('database reopen retains SMS budget and v12 migration preserves existing accounts and sessions', async t => {
  let store: Store;
  const path = productionEnv(t, () => { if (store?.db.isOpen) store.close(); }).DATABASE_PATH!;
  store = new Store(path);
  const dev = new AuthService(store, () => start);
  const session = dev.login({ mobile, code: (await dev.sendCode(mobile)).code });
  store.db.exec(`ALTER TABLE codes DROP COLUMN authMode; ALTER TABLE sessions DROP COLUMN authMode;
    DROP TABLE sms_send_attempts; DROP TABLE deployment_identity; PRAGMA user_version=12`);
  store.close();
  store = new Store(path);
  assert.equal(store.one('PRAGMA user_version')!.user_version, 13);
  assert.equal(store.one('SELECT authMode FROM sessions')!.authMode, 'development');
  assert.doesNotThrow(() => new AuthService(store, () => start).authenticate(`Bearer ${session.token}`));
  const options: AuthOptions = { mode: 'tencent', hourlyLimit: 1, dailyLimit: 1, globalDailyLimit: 1, sender: async () => {} };
  await new AuthService(store, () => start, options).sendCode(mobile);
  store.close();
  store = new Store(path);
  await assert.rejects(new AuthService(store, () => start + 60_000, options).sendCode('13900139000'), /上限/);
  assert.equal(store.one('SELECT mobileHash FROM sms_send_attempts')!.mobileHash, hash(mobile));
});

test('production refuses demo/legacy data and nonproduction refuses a production database', async t => {
  const env = productionEnv(t);
  const dev = createApp(readConfig({ DATABASE_PATH: env.DATABASE_PATH }), { pushTimer: false, log: () => {} });
  dev.store.close();
  assert.throws(() => createApp(readConfig(env)), /独立数据库/);
  const legacyEnv = { ...env, DATABASE_PATH: env.DATABASE_PATH + '.legacy' };
  const legacy = new Store(legacyEnv.DATABASE_PATH);
  legacy.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', 'demo', mobile, '演示管理员', 'admin');
  legacy.close();
  assert.throws(() => createApp(readConfig(legacyEnv)), /未核实账号/);
  const fresh = { ...env, DATABASE_PATH: env.DATABASE_PATH + '.fresh' };
  createApp(readConfig(fresh), { pushTimer: false }).store.close();
  createApp(readConfig(fresh), { pushTimer: false }).store.close();
  assert.throws(() => createApp(readConfig({ DATABASE_PATH: fresh.DATABASE_PATH })), /独立数据库/);
});

test('role CLI initializes a fresh production account with SMS guidance and rejects a development reopen', t => {
  const env = productionEnv(t);
  const args = ['--import', import.meta.resolve('tsx'),
    fileURLToPath(new URL('../../src/set-role.ts', import.meta.url)), mobile, 'admin'];
  const options = { cwd: dirname(env.DATABASE_PATH!), encoding: 'utf8' as const };
  const created = spawnSync(process.execPath, args, { ...options, env: { ...process.env, ...env } });
  assert.equal(created.status, 0, created.stderr);
  assert.match(created.stdout, /短信验证码/);
  const rejected = spawnSync(process.execPath, [...args.slice(0, -1), 'worker'], {
    ...options, env: { ...process.env, ...env, NODE_ENV: 'development', AUTH_MODE: 'development', PUBLIC_BASE_URL: 'http://127.0.0.1:3000' },
  });
  assert.notEqual(rejected.status, 0);
  assert.match(rejected.stderr, /独立数据库/);
  const service = createApp(readConfig(env), { pushTimer: false });
  try {
    assert.equal(service.store.one('SELECT role FROM users WHERE mobile=?', mobile)!.role, 'admin');
    assert.equal(service.store.one('SELECT environment FROM deployment_identity')!.environment, 'production');
  } finally { service.store.close(); }
});

test('production HTTP flow sends through the adapter, hides OTP and redacts provider failures', async t => {
  let cleanup = async () => {};
  const env = productionEnv(t, () => cleanup());
  const logs: object[] = [];
  let request: any;
  let fail = false;
  const { app, store } = createApp(readConfig(env), { pushTimer: false, log: event => logs.push(event), smsFetch: async (_url, init) => {
    request = JSON.parse(String(init!.body));
    return fail ? Response.json({ Response: { Error: { Code: 'InternalError', Message: `sensitive ${smsConfig.secretKey}` } } }) :
      accepted(request.PhoneNumberSet[0].slice(3));
  } });
  const server = app.listen(0, '127.0.0.1');
  cleanup = async () => { await new Promise<void>(resolve => server.close(() => resolve())); store.close(); };
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  const headers = { 'X-Client-Version': '1.0.0', 'X-Client-Platform': 'ohos', 'Content-Type': 'application/json' };
  const response = await fetch(`${base}/code?mobile=${mobile}`, { headers });
  assert.equal(response.status, 200);
  const receipt = await response.json() as any;
  assert.deepEqual(receipt.data, { development: false, expiresIn: 300 });
  const otp = request.TemplateParamSet[0];
  const login = await fetch(base + '/login', { method: 'POST', headers, body: JSON.stringify({ mobile, code: otp }) });
  const session = (await login.json() as any).data;
  assert.match(session.token, /^[a-f\d]{64}$/);
  assert.equal((await fetch(base + '/userInfo', { headers: { ...headers, Authorization: `Bearer ${session.token}` } })).status, 200);
  assert.deepEqual((await (await fetch(base + '/health')).json() as any).data, { mode: 'production', sms: true });
  fail = true;
  const failed = await fetch(base + '/code?mobile=13900139000', { headers });
  assert.equal(failed.status, 503);
  assert.match((await failed.json() as any).message, /发送未确认/);
  const captured = JSON.stringify(logs);
  for (const value of [mobile, '13900139000', otp, session.token, smsConfig.secretKey, smsConfig.secretId, 'sensitive'])
    assert.equal(captured.includes(value), false);
  assert(logs.some(event => (event as any).event === 'sms_send_failed'));
});

async function race(t: TestContext, path: string, action: string, phones: string[], code = '') {
  const children = phones.map(phone => fork(new URL('./auth-concurrency-worker.ts', import.meta.url),
    [path, action, phone, code, String(start)], { cwd: fileURLToPath(new URL('../../', import.meta.url)),
      execArgv: ['--import', 'tsx'], stdio: ['ignore', 'ignore', 'pipe', 'ipc'] }));
  t.after(() => { for (const child of children) child.kill(); });
  let vendorCalls = 0;
  const ready = children.map(child => new Promise<void>((resolve, reject) => {
    child.once('error', reject);
    child.on('message', (value: any) => { if (value.ready) resolve(); if (value.vendorCall) vendorCalls++; });
  }));
  const results = children.map(child => new Promise<boolean>((resolve, reject) => {
    let result: boolean | undefined;
    let stderr = '';
    child.stderr!.on('data', chunk => { stderr += chunk; });
    child.on('message', (value: any) => { if (typeof value.success === 'boolean') result = value.success; });
    child.once('error', reject);
    child.once('exit', status => { if (status === 0 && result !== undefined) resolve(result); else reject(Error(stderr)); });
  }));
  await Promise.all(ready);
  for (const child of children) child.send('go');
  return { results: await Promise.all(results), vendorCalls };
}

test('independent processes consume one OTP exactly once', { timeout: 20_000 }, async t => {
  let store: Store;
  const path = productionEnv(t, () => { if (store?.db.isOpen) store.close(); }).DATABASE_PATH!;
  store = new Store(path);
  const auth = new AuthService(store, () => start);
  const code = (await auth.sendCode(mobile)).code!;
  const { results } = await race(t, path, 'login', Array(4).fill(mobile), code);
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(store.one('SELECT COUNT(*) AS n FROM sessions')!.n, 1);
});

test('independent senders reserve global budget before calling the provider', { timeout: 20_000 }, async t => {
  let store: Store;
  const path = productionEnv(t, () => { if (store?.db.isOpen) store.close(); }).DATABASE_PATH!;
  store = new Store(path);
  const { results, vendorCalls } = await race(t, path, 'send', [mobile, '13900139000', '13700137000', '13600136000']);
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(vendorCalls, 1);
  assert.equal(store.one('SELECT COUNT(*) AS n FROM sms_send_attempts')!.n, 1);
});

test('independent senders cannot bypass the same phone cooldown', { timeout: 20_000 }, async t => {
  let store: Store;
  const path = productionEnv(t, () => { if (store?.db.isOpen) store.close(); }).DATABASE_PATH!;
  store = new Store(path);
  const { results, vendorCalls } = await race(t, path, 'send-phone', Array(4).fill(mobile));
  assert.equal(results.filter(Boolean).length, 1);
  assert.equal(vendorCalls, 1);
});
