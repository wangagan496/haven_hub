import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMaintenanceApp } from '../src/maintenance.js';
import { readConfig } from '../src/config.js';

test('maintenance rejects reads and writes without creating a database or running background settlement', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'haven-maintenance-'));
  const database = join(directory, 'never-open.sqlite');
  const config = readConfig({ DATABASE_PATH: database, MAINTENANCE_MODE: 'true' });
  assert.equal(config.maintenance, true);
  const server = createMaintenanceApp(config).listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  const address = server.address();
  assert(address && typeof address !== 'string');
  t.after(async () => {
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(directory, { recursive: true });
  });
  const base = `http://127.0.0.1:${address.port}`;
  for (const method of ['GET', 'POST', 'PUT', 'DELETE']) {
    for (const path of ['/ready', '/repair', '/room', '/code', '/upload', '/notifications']) {
      const response = await fetch(base + path, { method, headers: { Origin: config.publicBaseUrl } });
      assert.equal(response.status, 503);
      assert.equal((await response.json() as { code: number }).code, 50300);
      assert.equal(response.headers.get('retry-after'), '60');
      assert.equal(response.headers.get('access-control-allow-origin'), config.publicBaseUrl);
    }
  }
  assert.equal((await fetch(base + '/health')).status, 200);
  assert(!existsSync(database));
  assert(!existsSync(database + '-wal'));
  assert.throws(() => readConfig({ MAINTENANCE_MODE: 'yes' }));
});
