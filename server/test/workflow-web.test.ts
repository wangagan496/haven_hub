import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';

test('demo serves the compiled web entry while keeping worker APIs authenticated', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-web-'));
  const { app, store } = createApp({ ...readConfig({}), databasePath: ':memory:' }, {
    workflowWebRoot: root, log: () => {},
  });
  const server = app.listen(0, '127.0.0.1');
  t.after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close(error => error ? reject(error) : resolve());
      server.closeIdleConnections();
    });
    store.close();
    rmSync(root, { recursive: true });
  });
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  const base = `http://127.0.0.1:${address.port}`;
  const missing = await fetch(`${base}/workflow/`);
  assert.equal(missing.status, 503);
  assert.match(await missing.text(), /build_workflow_web/);
  writeFileSync(join(root, 'index.html'), '<html><body>demo app</body></html>');
  writeFileSync(join(root, 'main.dart.js'), 'window.demo = true;');
  const page = await fetch(`${base}/workflow/`);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /demo app/);
  assert.match(page.headers.get('content-security-policy')!, /wasm-unsafe-eval/);
  assert.match(page.headers.get('content-security-policy')!, /http:\/\/127\.0\.0\.1:3001\/tencent-map\//);
  assert.doesNotMatch(page.headers.get('content-security-policy')!, /upgrade-insecure-requests/);
  assert.equal((await fetch(`${base}/workflow/main.dart.js`)).status, 200);
  assert.equal((await fetch(`${base}/workflow/missing.js`)).status, 404);
  assert.equal((await fetch(`${base}/worker/repairs`)).status, 401);
  assert.equal((await fetch(`${base}/workflow/%2e%2e%2fpackage.json`)).status, 404);
  const admin = await fetch(`${base}/admin/`);
  assert.equal(admin.status, 200);
  assert.doesNotMatch(admin.headers.get('content-security-policy')!, /wasm-unsafe-eval/);
});
