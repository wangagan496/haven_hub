import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync, readdirSync, mkdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/database.js';
import { createBackupKey, readBackupKey, createEncryptedBackup, restoreEncryptedBackup, verifyEncryptedBackup } from '../src/encrypted-backup.js';

test('encrypted online snapshot restores WAL data, images and audit while keeping metadata confidential', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-test-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  store.db.exec('PRAGMA wal_autocheckpoint=0');
  store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('audit-admin','13800138000','private-owner','admin')");
  store.save('rooms', 'audit-admin', { id: 'room-one', name: 'private-owner', room: '101' });
  const photo = Buffer.from('private-photo-payload');
  store.run('INSERT INTO uploads VALUES (?,?,?,?)', 'b'.repeat(64), 'audit-admin', 'image/png', photo);
  store.run("INSERT INTO management_audit(actorId,actorRole,action,targetType,targetId,createdAt,beforeJson,afterJson,source) VALUES ('audit-admin','admin','room.review','room','room-one',1,'null','{}','live')");
  assert(existsSync(source + '-wal'));
  const sealed = join(root, 'sealed'), restored = join(root, 'restored');
  const manifest = await createEncryptedBackup(source, sealed, key);
  assert.deepEqual(readdirSync(sealed).sort(), ['database.enc', 'manifest.enc']);
  for (const file of readdirSync(sealed)) {
    const bytes = readFileSync(join(sealed, file));
    for (const value of ['SQLite format 3', 'private-owner', 'private-photo-payload', 'databaseSha256']) assert(!bytes.includes(Buffer.from(value)));
  }
  assert.deepEqual(await verifyEncryptedBackup(sealed, key), manifest);
  store.save('rooms', 'audit-admin', { id: 'room-one', room: '102' }, true);
  assert.deepEqual(await restoreEncryptedBackup(sealed, restored, key), manifest);
  const recovered = new Store(join(restored, 'database.sqlite'));
  try {
    assert.equal(recovered.get('rooms', 'audit-admin', 'room-one')!.room, '101');
    assert.deepEqual(Buffer.from(recovered.one('SELECT bytes FROM uploads')!.bytes as Uint8Array), photo);
    assert.equal(recovered.one('SELECT COUNT(*) AS n FROM management_audit')!.n, 1);
    assert.throws(() => recovered.run('DELETE FROM management_audit'), /append-only/);
    assert.equal(store.get('rooms', 'audit-admin', 'room-one')!.room, '102');
  } finally { recovered.close(); }
});

test('wrong key, modified ciphertext and truncated envelopes never produce a restored backup', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-corrupt-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  const sealed = join(root, 'sealed');
  await createEncryptedBackup(source, sealed, key);
  const output = join(root, 'restored');
  const privateTemps = () => readdirSync(root).filter(name => name.startsWith(`.haven-backup-private-${process.pid}-`)).sort();
  const beforeTemps = privateTemps();
  await assert.rejects(restoreEncryptedBackup(sealed, output, randomBytes(32)));
  assert(!existsSync(output));
  for (const name of ['database.enc', 'manifest.enc']) {
    const file = join(sealed, name), original = readFileSync(file);
    for (const offset of [0, 8, 24, original.length - 1]) {
      const changed = Buffer.from(original); changed[offset] = changed[offset]! ^ 1; writeFileSync(file, changed);
      await assert.rejects(restoreEncryptedBackup(sealed, output, key));
      assert(!existsSync(output));
    }
    writeFileSync(file, original.subarray(0, 30));
    await assert.rejects(verifyEncryptedBackup(sealed, key));
    writeFileSync(file, original);
  }
  assert.equal((await verifyEncryptedBackup(sealed, key)).schemaVersion, 13);
  assert.deepEqual(privateTemps(), beforeTemps, 'failed verification must remove its own private plaintext staging directories');
});

test('verification plaintext is created only in a private directory under the backup root', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-private-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  const sealed = join(root, 'sealed');
  await createEncryptedBackup(source, sealed, key);
  const writeStream = fs.createWriteStream;
  const plaintext: string[] = [];
  const observer = t.mock.method(fs, 'createWriteStream', (...args: Parameters<typeof fs.createWriteStream>) => {
    const path = String(args[0]);
    if (['database.sqlite', 'manifest.json'].includes(basename(path))) {
      plaintext.push(path);
      assert.equal(dirname(dirname(path)), root);
      assert(basename(dirname(path)).startsWith('.haven-backup-private-'));
      if (process.platform !== 'win32') assert.equal(statSync(dirname(path)).mode & 0o777, 0o700);
      assert.equal((args[1] as { mode: number }).mode, 0o600);
    }
    return writeStream(...args);
  });
  syncBuiltinESMExports();
  try { await verifyEncryptedBackup(sealed, key); }
  finally { observer.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(plaintext.length, 2);
  for (const path of plaintext) assert(!existsSync(dirname(path)));
});

test('fresh nonces differ and swapping file roles or snapshots is rejected', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-binding-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  const a = join(root, 'a'), b = join(root, 'b'), c = join(root, 'c');
  await createEncryptedBackup(source, a, key); await createEncryptedBackup(source, b, key);
  const first = readFileSync(join(a, 'database.enc')), second = readFileSync(join(b, 'database.enc'));
  assert(!first.subarray(8, 20).equals(second.subarray(8, 20)));
  assert(!readFileSync(join(a, 'manifest.enc')).subarray(8, 20).equals(first.subarray(8, 20)));
  writeFileSync(join(b, 'manifest.enc'), second);
  await assert.rejects(verifyEncryptedBackup(b, key));
  store.run("INSERT INTO users(id,mobile,nickName) VALUES ('different','13800138001','another-snapshot')");
  await createEncryptedBackup(source, c, key);
  writeFileSync(join(c, 'database.enc'), first);
  await assert.rejects(restoreEncryptedBackup(c, join(root, 'restored'), key), /校验失败/);
  assert(!existsSync(join(root, 'restored')));
});

test('existing destinations are never changed and failed creation cleans only its own files', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-destination-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  const existing = join(root, 'existing'); mkdirSync(existing); writeFileSync(join(existing, 'keep.txt'), 'keep');
  await assert.rejects(createEncryptedBackup(source, existing, key));
  await assert.rejects(restoreEncryptedBackup(join(root, 'missing'), existing, key));
  assert.equal(readFileSync(join(existing, 'keep.txt'), 'utf8'), 'keep');
  const target = join(root, 'failed');
  await assert.rejects(createEncryptedBackup(join(root, 'missing.sqlite'), target, key));
  assert(!existsSync(target));
  writeFileSync(join(root, 'invalid.sqlite'), 'not-a-database');
  await assert.rejects(createEncryptedBackup(join(root, 'invalid.sqlite'), target, key));
  assert(!existsSync(target));
  for (const length of [0, 16, 31, 33, 64]) {
    await assert.rejects(createEncryptedBackup(source, target, Buffer.alloc(length)), /32字节/);
    assert(!existsSync(target));
  }
});

test('missing or non-file ciphertext inputs fail without leaving plaintext and never change source', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-files-'));
  const source = join(root, 'source.sqlite'), store = new Store(source), key = randomBytes(32);
  t.after(() => { store.close(); key.fill(0); rmSync(root, { recursive: true }); });
  const sealed = join(root, 'sealed'), output = join(root, 'restored');
  await createEncryptedBackup(source, sealed, key);
  const file = join(sealed, 'database.enc'), bytes = readFileSync(file);
  rmSync(file);
  await assert.rejects(restoreEncryptedBackup(sealed, output, key));
  assert(!existsSync(output));
  mkdirSync(file);
  await assert.rejects(restoreEncryptedBackup(sealed, output, key), /普通文件/);
  assert(!existsSync(output));
  rmSync(file, { recursive: true }); writeFileSync(file, bytes);
  assert.equal((await verifyEncryptedBackup(sealed, key)).schemaVersion, 13);
  assert.deepEqual(readFileSync(file), bytes);
});

test('key generation is exclusive and binary; invalid key files are rejected', t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-backup-keys-'));
  t.after(() => rmSync(root, { recursive: true }));
  const directory = join(root, 'key-dir'), file = createBackupKey(directory), key = readBackupKey(file);
  assert.equal(key.length, 32);
  assert.throws(() => createBackupKey(directory));
  assert.deepEqual(readFileSync(file), key);
  assert.throws(() => readBackupKey(directory));
  for (const content of ['', 'a'.repeat(64), 'human-password']) {
    const invalid = join(root, 'invalid.key'); writeFileSync(invalid, content);
    assert.throws(() => readBackupKey(invalid));
  }
  if (process.platform !== 'win32') {
    assert.equal(statSync(directory).mode & 0o777, 0o700);
    assert.equal(statSync(file).mode & 0o777, 0o600);
  }
  key.fill(0);
});

test('key rotation creates independently recoverable backups without rewriting the old backup', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-backup-rotation-'));
  const source = join(root, 'source.sqlite'), store = new Store(source);
  const oldKey = randomBytes(32), newKey = randomBytes(32);
  t.after(() => { store.close(); oldKey.fill(0); newKey.fill(0); rmSync(root, { recursive: true }); });
  const oldBackup = join(root, 'old'), newBackup = join(root, 'new');
  await createEncryptedBackup(source, oldBackup, oldKey);
  const bytes = readFileSync(join(oldBackup, 'database.enc'));
  await createEncryptedBackup(source, newBackup, newKey);
  await assert.rejects(verifyEncryptedBackup(oldBackup, newKey));
  await assert.rejects(verifyEncryptedBackup(newBackup, oldKey));
  assert.equal((await verifyEncryptedBackup(oldBackup, oldKey)).schemaVersion, 13);
  assert.equal((await verifyEncryptedBackup(newBackup, newKey)).schemaVersion, 13);
  assert.deepEqual(readFileSync(join(oldBackup, 'database.enc')), bytes);
});

test('real CLI generates a key and creates, verifies, restores encrypted backup without leaking secrets', async t => {
  const root = mkdtempSync(join(tmpdir(), 'haven-encrypted-cli-'));
  const source = join(root, 'source.sqlite'), store = new Store(source);
  store.run("INSERT INTO users(id,mobile,nickName) VALUES ('cli-user','13800138001','private-cli-name')");
  store.close(); t.after(() => rmSync(root, { recursive: true }));
  const cli = fileURLToPath(new URL('../tool/database-backup.ts', import.meta.url));
  const cwd = fileURLToPath(new URL('../', import.meta.url));
  const keyDirectory = join(root, 'keys'), keyFile = join(keyDirectory, 'backup.key'), sealed = join(root, 'sealed'), restored = join(root, 'restored');
  function run(args: string[], keyPath = keyFile) {
    const result = spawnSync(process.execPath, ['--import', 'tsx', cli, ...args], { cwd, env: { ...process.env, BACKUP_KEY_FILE: keyPath }, encoding: 'utf8', timeout: 20000, windowsHide: true });
    assert.ifError(result.error);
    assert.doesNotMatch(result.stdout + result.stderr, /private-cli-name|13800138001/);
    if (existsSync(keyFile)) assert(!(result.stdout + result.stderr).includes(readFileSync(keyFile).toString('hex')));
    return result;
  }
  assert.equal(run(['keygen', keyDirectory]).status, 0);
  assert.equal(run(['create-encrypted', source, sealed]).status, 0);
  assert.equal(run(['verify-encrypted', sealed]).status, 0);
  const restore = run(['restore-encrypted', sealed, restored]);
  assert.equal(restore.status, 0);
  assert.equal(JSON.parse(restore.stdout).destinationEncrypted, false);
  const recovered = new Store(join(restored, 'database.sqlite'));
  try { assert.equal(recovered.one("SELECT nickName FROM users WHERE id='cli-user'")!.nickName, 'private-cli-name'); }
  finally { recovered.close(); }
  assert.equal(run(['verify-encrypted', sealed], '').status, 1);
  assert.equal(run(['restore-encrypted', sealed, restored]).status, 1);
  assert.equal(run(['keygen', keyDirectory, 'extra']).status, 1);
  assert.equal(run(['verify', sealed]).status, 1);
  const plain = join(root, 'plain');
  assert.equal(run(['create', source, plain]).status, 0);
  assert.equal(run(['verify', plain]).status, 0);
  assert.equal(run(['restore', plain, join(root, 'plain-restored')]).status, 0);
});
