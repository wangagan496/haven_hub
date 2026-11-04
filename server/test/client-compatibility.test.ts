import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { AuthService } from '../src/auth.js';

async function fixture(t: TestContext, minimum = '1.2.0') {
  const config = readConfig({ DATABASE_PATH: ':memory:', CLIENT_MIN_VERSION: minimum });
  const { app, store, notifications } = createApp(config, { log: () => {}, pushTimer: false });
  const auth = new AuthService(store);
  const mobile = '13800138000';
  const session = auth.login({ mobile, code: (await auth.sendCode(mobile)).code });
  const server = app.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  t.after(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    await notifications.stop();
    store.close();
  });
  const base = `http://127.0.0.1:${address.port}`;
  const headers = { Authorization: `Bearer ${session.token}`, 'X-Client-Version': '1.2.0', 'X-Client-Platform': 'ohos' };
  return { base, store, session, headers, config };
}

test('version enforcement is opt-in and preserves unversioned local clients by default', async t => {
  const { base, session } = await fixture(t, '');
  const response = await fetch(base + '/userInfo', { headers: { Authorization: `Bearer ${session.token}` } });
  assert.equal(response.status, 200);
  assert.equal((await response.json() as any).code, 10000);
});

test('configured versions must be canonical release triples', () => {
  for (const value of ['1.2', '01.2.3', '1.2.3-beta', '1.2.3+4', ' 1.2.3', '9999999.0.0', 'NaN', '1.2.3,2.0.0']) {
    assert.throws(() => readConfig({ CLIENT_MIN_VERSION: value }), value);
  }
  assert.doesNotThrow(() => readConfig({ CLIENT_MIN_VERSION: '0.0.0' }));
  assert.throws(() => readConfig({ NODE_ENV: 'production', CLIENT_MIN_VERSION: '1.0.0' }));
});

test('missing, malformed and old metadata are rejected without running read-side settlement or writes', async t => {
  const { base, store, headers } = await fixture(t);
  const cases: Record<string, string>[] = [
    {},
    { 'X-Client-Version': '1.2.0' },
    { 'X-Client-Platform': 'ohos' },
    { 'X-Client-Version': '1.1.99', 'X-Client-Platform': 'ohos' },
    { 'X-Client-Version': '01.2.0', 'X-Client-Platform': 'web' },
    { 'X-Client-Version': '1.2.0-beta', 'X-Client-Platform': 'web' },
    { 'X-Client-Version': '1.2.0, 9.0.0', 'X-Client-Platform': 'web' },
    { 'X-Client-Version': '9999999.0.0', 'X-Client-Platform': 'web' },
    { 'X-Client-Version': '1.2.0', 'X-Client-Platform': 'admin' },
    { 'X-Client-Version': '1.2.0', 'X-Client-Platform': 'ohos, web' },
  ];
  const before = store.one('SELECT total_changes() AS count')?.count;
  for (const metadata of cases) {
    for (const [method, path] of [['GET','/repair'], ['GET','/notifications'], ['GET','/code?mobile=13900139000'],
      ['POST','/login'], ['POST','/refreshToken'], ['POST','/room'], ['PUT','/userInfo'], ['DELETE','/room/example'],
      ['POST','/upload'], ['PUT','/management/rooms/example/review']]) {
      const response = await fetch(base + path, { method, headers: { Authorization: headers.Authorization, ...metadata } });
      assert.equal(response.status, 426, `${method} ${path} ${JSON.stringify(metadata)}`);
      const body = await response.json() as any;
      assert.equal(body.code, 42600);
      assert.equal(body.data.minimumVersion, '1.2.0');
      assert.match(body.message, /升级/);
      assert.match(response.headers.get('x-request-id')!, /^[a-f0-9-]{36}$/);
    }
  }
  assert.equal(store.one('SELECT total_changes() AS count')?.count, before);
});

test('numeric version ordering admits supported platforms without granting management permissions', async t => {
  const { base, headers } = await fixture(t, '1.9.9');
  for (const version of ['1.9.9', '1.10.0', '2.0.0']) {
    for (const platform of ['ohos','web','android','ios','linux','macos','windows','fuchsia','admin-web']) {
      const current = { ...headers, 'X-Client-Version': version, 'X-Client-Platform': platform };
      assert.equal((await fetch(base + '/userInfo', { headers: current })).status, 200);
    }
  }
  const spoofedAdmin = { ...headers, 'X-Client-Version': '2.0.0', 'X-Client-Platform': 'admin-web' };
  assert.equal((await fetch(base + '/management/rooms', { headers: spoofedAdmin })).status, 403);
  assert.equal((await fetch(base + '/userInfo', { headers: { 'X-Client-Version': '2.0.0', 'X-Client-Platform': 'ohos' } })).status, 401);
  assert.equal((await fetch(base + '/userInfo', { headers: { ...spoofedAdmin, 'X-Client-Version': '1.9.8' } })).status, 426);
});

test('health, readiness, static admin assets and validated push revocation stay reachable', async t => {
  const { base, store } = await fixture(t);
  for (const path of ['/health', '/ready', '/admin/', '/admin/app.js']) {
    assert.equal((await fetch(base + path)).status, 200);
  }
  const before = store.one('SELECT total_changes() AS count')?.count;
  const revoked = await fetch(base + '/notifications/unregister', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
  assert.notEqual(revoked.status, 426);
  assert.notEqual((await revoked.json() as any).code, 10000);
  assert.equal(store.one('SELECT total_changes() AS count')?.count, before);
});

test('CORS accepts version metadata while rejected clients retain readable upgrade receipts', async t => {
  const { base, config } = await fixture(t);
  const preflight = await fetch(base + '/room', { method: 'OPTIONS', headers: { Origin: config.publicBaseUrl,
    'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'x-client-version,x-client-platform,authorization,content-type' } });
  assert.equal(preflight.status, 204);
  assert.match(preflight.headers.get('access-control-allow-headers')!, /x-client-version/i);
  const rejected = await fetch(base + '/room', { method: 'POST', headers: { Origin: config.publicBaseUrl } });
  assert.equal(rejected.status, 426);
  assert.equal(rejected.headers.get('access-control-allow-origin'), config.publicBaseUrl);
  assert.match(rejected.headers.get('access-control-expose-headers')!, /X-Request-Id/i);
});

test('every requesting admin page uses the shared server version after the minimum is raised', async t => {
  const { base, headers, store } = await fixture(t, '9.4.2');
  store.run("UPDATE users SET role='admin'");
  const versionResponse = await fetch(base + '/admin/client-version.js');
  assert.equal(versionResponse.status, 200);
  const context = { window: {} as { HAVEN_ADMIN_CLIENT_VERSION?: string } };
  runInNewContext(await versionResponse.text(), context);
  assert.equal(context.window.HAVEN_ADMIN_CLIENT_VERSION, '9.4.2');
  const root = new URL('../public/admin/', import.meta.url);
  const requestingPages = readdirSync(root).filter(name => name.endsWith('.js') && /fetch\(/.test(readFileSync(new URL(name, root), 'utf8')));
  assert.deepEqual(requestingPages.sort(), ['app.js', 'audit.js']);
  for (const name of requestingPages) {
    const source = readFileSync(new URL(name, root), 'utf8');
    const header = /const (\w+Headers) = ([^;]+);/.exec(source)!;
    assert(header, name);
    const metadata = runInNewContext(`(${header[2]})`, context) as Record<string, string>;
    assert.equal(metadata['X-Client-Version'], '9.4.2');
    const html = readFileSync(new URL(name === 'app.js' ? 'index.html' : name.replace('.js', '.html'), root), 'utf8');
    assert(html.indexOf('./client-version.js') >= 0 && html.indexOf('./client-version.js') < html.indexOf(`./${name}`), name);
    const endpoint = name === 'app.js' ? '/management/rooms' : '/management/audit-events';
    assert.equal((await fetch(base + endpoint, { headers: { ...headers, ...metadata } })).status, 200, name);
  }
});

test('build wrapper derives version from pubspec and validates build-name overrides', () => {
  const script = fileURLToPath(new URL('../../tool/test_client_version.ps1', import.meta.url));
  const result = spawnSync('pwsh', ['-File', script], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /RESULT script=.*version-source=pubspec/);
});
