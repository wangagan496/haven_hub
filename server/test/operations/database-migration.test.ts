import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fixture } from '../helpers/api-fixture.js';

test('version one database migration preserves resident data and defaults role safely', async t => {
  const folder = mkdtempSync(join(tmpdir(), 'haven-migration-'));
  const path = join(folder, 'database.sqlite');
  const original = await fixture(t, path);
  const session = await original.login();
  const house = await original.room(session.token);
  original.store.db.exec('DROP TABLE repair_capacity_weekdays; ALTER TABLE users DROP COLUMN role; PRAGMA user_version = 1;');
  await original.close();
  const migrated = await fixture(t, path);
  assert.equal(migrated.store.one('PRAGMA user_version')?.user_version, 13);
  assert.equal((await migrated.request('GET', '/userInfo', session.token)).data.role, 'resident');
  assert.equal((await migrated.request('GET', `/room/${house.record.id}`, session.token)).data.name, house.record.name);
  await migrated.close();
  rmSync(path);
  rmdirSync(folder);
});
