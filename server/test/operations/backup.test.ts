import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackup, restoreBackup, verifyBackup } from '../../src/backup.js';
import { Store } from '../../src/database.js';
import { randomUUID } from 'node:crypto';

test('online backup includes committed WAL data and restores every table and image without changing the active database', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'haven-backup-'));
  const live = join(dir, 'live.sqlite');
  const store = new Store(live);
  t.after(() => { store.close(); rmSync(dir, { recursive: true }); });
  store.db.exec('PRAGMA wal_autocheckpoint=0');
  const owner = randomUUID(), house = randomUUID(), repair = randomUUID();
  store.run('INSERT INTO users(id,mobile,nickName) VALUES (?,?,?)', owner, '13800138000', '备份验收');
  store.save('rooms', owner, { id: house, name: '测试业主', room: '101' });
  store.save('repairs', owner, { id: repair, houseId: house, description: '需要恢复的报修', revision: 2 });
  const visitor = randomUUID(), submission = randomUUID(), notice = randomUUID();
  store.save('visitors', owner, { id: visitor, name: '访客验收', houseId: house });
  store.run('INSERT INTO repair_submissions VALUES (?,?,?,?,?)', owner, submission, 'request-hash', repair, 1);
  store.run('INSERT INTO visitor_submissions VALUES (?,?,?,?,?)', owner, submission, 'visitor-request-hash', visitor, 1);
  const closedSubmission = randomUUID();
  store.run('INSERT INTO visitor_submissions VALUES (?,?,?,NULL,?)', owner, closedSubmission, '', 1);
  store.run('INSERT INTO room_submissions VALUES (?,?,?,?,?)', owner, submission, 'room-hash', house, 1);
  store.run('INSERT INTO room_submissions VALUES (?,?,?,NULL,?)', owner, closedSubmission, '', 1);
  const deletedSubmission = randomUUID(), deletedHouse = randomUUID();
  store.run('INSERT INTO room_submissions VALUES (?,?,?,?,?)', owner, deletedSubmission, 'deleted-room-hash', deletedHouse, 1);
  store.run('INSERT INTO notifications(id,userId,repairId,taskKey,role,title,body,active,createdAt) VALUES (?,?,?,?,?,?,?,?,?)',
    notice, owner, repair, 'confirm', 'resident', '待确认', '验收通知', 1, 1);
  const image = Buffer.from('private-image-bytes');
  store.run('INSERT INTO uploads VALUES (?,?,?,?)', 'a'.repeat(64), owner, 'image/png', image);
  store.run('INSERT INTO sms_send_attempts(mobileHash,sentAt) VALUES (?,?)', 'synthetic-mobile-hash', 1000);
  store.run("INSERT INTO deployment_identity VALUES (1,'production')");
  assert(existsSync(`${live}-wal`));
  const backup = join(dir, 'backup'), restored = join(dir, 'restored');
  const manifest = await createBackup(live, backup);
  assert.equal(manifest.tables.users!.rows, 1);
  store.save('rooms', owner, { id: house, name: '稍后修改', room: '102' }, true);
  assert.deepEqual(await restoreBackup(backup, restored), manifest);
  const recovered = new Store(join(restored, 'database.sqlite'));
  try {
    assert.equal(recovered.get('rooms', owner, house)!.room, '101');
    assert.equal(recovered.get('repairs', owner, repair)!.description, '需要恢复的报修');
    assert.equal(recovered.get('visitors', owner, visitor)!.name, '访客验收');
    assert.equal(recovered.one('SELECT repairId FROM repair_submissions WHERE submissionId=?', submission)!.repairId, repair);
    assert.equal(recovered.one('SELECT visitorId FROM visitor_submissions WHERE submissionId=?', submission)!.visitorId, visitor);
    assert.equal(recovered.one('SELECT visitorId FROM visitor_submissions WHERE submissionId=?', closedSubmission)!.visitorId, null);
    assert.equal(recovered.one('SELECT roomId FROM room_submissions WHERE submissionId=?', submission)!.roomId, house);
    assert.equal(recovered.one('SELECT roomId FROM room_submissions WHERE submissionId=?', closedSubmission)!.roomId, null);
    assert.equal(recovered.one('SELECT roomId FROM room_submissions WHERE submissionId=?', deletedSubmission)!.roomId, deletedHouse);
    assert.equal(recovered.one('SELECT body FROM notifications WHERE id=?', notice)!.body, '验收通知');
    assert.deepEqual(Buffer.from(recovered.one('SELECT bytes FROM uploads')!.bytes as Uint8Array), image);
    assert.equal(recovered.one('SELECT mobileHash FROM sms_send_attempts')!.mobileHash, 'synthetic-mobile-hash');
    assert.equal(recovered.one('SELECT environment FROM deployment_identity')!.environment, 'production');
    assert.equal(store.get('rooms', owner, house)!.room, '102');
  } finally { recovered.close(); }
  assert.equal(await verifyBackup(backup).then(value => value.databaseSha256), manifest.databaseSha256);
});

test('backup and restore refuse existing destinations and corrupt copies', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'haven-backup-safety-'));
  const store = new Store(join(dir, 'source.sqlite'));
  t.after(() => { store.close(); rmSync(dir, { recursive: true }); });
  const target = join(dir, 'backup');
  await createBackup(join(dir, 'source.sqlite'), target);
  const original = readFileSync(join(target, 'database.sqlite'));
  await assert.rejects(createBackup(join(dir, 'source.sqlite'), target));
  await assert.rejects(restoreBackup(target, target));
  assert.deepEqual(readFileSync(join(target, 'database.sqlite')), original);
  writeFileSync(join(target, 'database.sqlite'), original.subarray(0, 100));
  await assert.rejects(verifyBackup(target), /校验失败/);
  const restored = join(dir, 'restore');
  await assert.rejects(restoreBackup(target, restored), /校验失败/);
  assert(!existsSync(restored));
});

test('version-eight backup survives migration failure and restores to a separately upgraded database', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'haven-backup-migration-'));
  const source = join(dir, 'source.sqlite');
  const old = new Store(source);
  old.db.exec('DROP TABLE room_submissions; DROP TABLE visitor_submissions; DROP TABLE upload_bindings; DROP TABLE account_events; ALTER TABLE users DROP COLUMN disabledAt; PRAGMA user_version=8');
  old.run('INSERT INTO users(id,mobile,nickName) VALUES (?,?,?)', 'old-user', '13800138000', '迁移保留');
  const manifest = await createBackup(source, join(dir, 'backup'));
  old.close();
  t.after(() => rmSync(dir, { recursive: true }));
  assert.equal(manifest.schemaVersion, 8);
  await restoreBackup(join(dir, 'backup'), join(dir, 'candidate'));
  const upgraded = new Store(join(dir, 'candidate', 'database.sqlite'));
  try {
    assert.equal(upgraded.one('PRAGMA user_version')!.user_version, 13);
    assert.equal(upgraded.one("SELECT disabledAt FROM users WHERE id='old-user'")!.disabledAt, 0);
    assert.throws(() => upgraded.transaction(() => {
      upgraded.db.exec('DROP TABLE uploads');
      throw new Error('injected failed migration');
    }), /failed migration/);
    assert(upgraded.one("SELECT name FROM sqlite_schema WHERE name='uploads'"));
  } finally { upgraded.close(); }
  assert.deepEqual(await verifyBackup(join(dir, 'backup')), manifest);
});
