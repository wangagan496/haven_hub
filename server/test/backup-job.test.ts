import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
import { Store } from '../src/database.js';
import { createBackupKey, readBackupKey, restoreEncryptedBackup, verifyEncryptedBackup } from '../src/encrypted-backup.js';
import { readBackupJobConfig, runBackupJob, type BackupJobConfig } from '../src/backup-job.js';

function fixture(t: test.TestContext) {
  const root = mkdtempSync(join(tmpdir(), 'haven-backup-job-'));
  const source = join(root, 'source.sqlite'), store = new Store(source);
  const keyFile = createBackupKey(join(root, 'keys'));
  const config: BackupJobConfig = { database: source, directory: join(root, 'local'), replicaDirectory: join(root, 'replica'), keep: 2 };
  t.after(() => { store.close(); rmSync(root, { recursive: true, force: true }); });
  const snapshots = (directory: string) => readdirSync(directory).filter(name => name.startsWith('snapshot-')).sort();
  return { root, store, keyFile, config, snapshots };
}

test('scheduled job creates two encrypted verified copies, restores WAL data and retains latest two', async t => {
  const { root, store, keyFile, config, snapshots } = fixture(t);
  store.db.exec('PRAGMA wal_autocheckpoint=0');
  store.run("INSERT INTO users(id,mobile,nickName) VALUES ('job-user','13800138000','job-private-name')");
  const results = [];
  for (let n = 1; n <= 3; n++) {
    store.save('rooms', 'job-user', { id: 'job-room', room: String(n) }, n > 1);
    results.push(await runBackupJob(config, keyFile));
  }
  assert.equal(results[2]!.removed, 2);
  for (const directory of [config.directory, config.replicaDirectory]) {
    assert.deepEqual(snapshots(directory), results.slice(1).map(result => result.snapshot).sort());
    assert(!existsSync(join(directory, '.haven-backup-job.lock')));
    for (const name of snapshots(directory)) assert.deepEqual(readdirSync(join(directory, name)).sort(), ['database.enc', 'manifest.enc']);
  }
  const key = readBackupKey(keyFile), restored = join(root, 'restored');
  try {
    await restoreEncryptedBackup(join(config.replicaDirectory, results[2]!.snapshot), restored, key);
    const recovered = new Store(join(restored, 'database.sqlite'));
    try { assert.equal(recovered.get('rooms', 'job-user', 'job-room')!.room, '3'); }
    finally { recovered.close(); }
  } finally { key.fill(0); }
});

test('another process holding either root prevents overlap without stealing or deleting its lock', async t => {
  const { root, keyFile, config, snapshots } = fixture(t);
  await runBackupJob(config, keyFile);
  const lock = join(config.replicaDirectory, '.haven-backup-job.lock');
  const holder = spawn(process.execPath, ['-e', 'require("node:fs").writeFileSync(process.argv[1],JSON.stringify({pid:process.pid,startedAt:new Date(performance.timeOrigin).toISOString()}),{flag:"wx"});process.stdout.write("locked\\n");setInterval(()=>{},1000)', lock],
    { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  t.after(() => holder.kill());
  await new Promise<void>((resolve, reject) => { holder.once('error', reject); holder.once('exit', () => reject(new Error('lock holder exited'))); holder.stdout.once('data', () => resolve()); });
  const before = snapshots(config.directory);
  const owner = readFileSync(lock, 'utf8');
  await assert.rejects(runBackupJob(config, keyFile), /锁被占用/);
  assert.equal(readFileSync(lock, 'utf8'), owner);
  assert(!existsSync(join(config.directory, '.haven-backup-job.lock')));
  assert.deepEqual(snapshots(config.directory), before);
  holder.kill();
  await new Promise<void>(resolve => holder.once('exit', () => resolve()));
  // A killed process leaves a valid receipt; the next job must recover it.
  assert.equal((await runBackupJob(config, keyFile)).copies, 2);
  assert(existsSync(root));
});

test('damaged historical replica is preserved with a warning while other expired snapshots are pruned', async t => {
  const { keyFile, config, snapshots } = fixture(t);
  const first = await runBackupJob(config, keyFile);
  const second = await runBackupJob(config, keyFile);
  writeFileSync(join(config.replicaDirectory, first.snapshot, 'database.enc'), 'broken');
  const current = await runBackupJob(config, keyFile);
  assert.equal(current.status, 'warning');
  assert.equal(current.invalidSnapshots, 1);
  assert.equal(current.removed, 1);
  assert.equal(snapshots(config.directory).length, 2);
  assert.equal(snapshots(config.replicaDirectory).length, 3);
  assert(!existsSync(join(config.directory, first.snapshot)));
  assert.equal(readFileSync(join(config.replicaDirectory, first.snapshot, 'database.enc'), 'utf8'), 'broken');
  const next = await runBackupJob(config, keyFile);
  assert.equal(next.status, 'warning');
  assert.equal(next.removed, 2);
  assert(!existsSync(join(config.replicaDirectory, second.snapshot)));
  assert(!existsSync(join(config.directory, '.haven-backup-job.lock')));
});

test('unknown files and foreign source identity never get removed by retention', async t => {
  const { root, keyFile, config } = fixture(t);
  const first = await runBackupJob(config, keyFile);
  writeFileSync(join(config.directory, first.snapshot, 'keep.txt'), 'operator-owned');
  assert.equal((await runBackupJob(config, keyFile)).status, 'warning');
  assert.equal(readFileSync(join(config.directory, first.snapshot, 'keep.txt'), 'utf8'), 'operator-owned');
  const other = new Store(join(root, 'other.sqlite')); other.close();
  await assert.rejects(runBackupJob({ ...config, database: join(root, 'other.sqlite') }, keyFile));
});

test('nested roots, co-located key or database, nonempty roots and invalid retention fail safely', async t => {
  const { root, keyFile, config } = fixture(t);
  await assert.rejects(runBackupJob({ ...config, keep: 1 }, keyFile));
  await assert.rejects(runBackupJob({ ...config, replicaDirectory: config.directory }, keyFile));
  mkdirSync(config.directory);
  await assert.rejects(runBackupJob({ ...config, replicaDirectory: join(config.directory, 'nested') }, keyFile));
  await assert.rejects(runBackupJob({ ...config, directory: root }, keyFile));
  await assert.rejects(runBackupJob({ ...config, directory: join(root, 'keys') }, keyFile));
  writeFileSync(join(config.directory, 'foreign.txt'), 'keep');
  await assert.rejects(runBackupJob(config, keyFile), /空的专用/);
  assert.equal(readFileSync(join(config.directory, 'foreign.txt'), 'utf8'), 'keep');
});

test('copy failure preserves verified staging locally and does not prune old copies', async t => {
  const { keyFile, config, snapshots } = fixture(t);
  const first = await runBackupJob(config, keyFile);
  const originalCopy = fs.copyFileSync;
  const fault = t.mock.method(fs, 'copyFileSync', (...args: Parameters<typeof fs.copyFileSync>) => {
    originalCopy(...args);
    throw new Error('injected replica IO failure after partial copy');
  });
  syncBuiltinESMExports();
  try { await assert.rejects(runBackupJob(config, keyFile), /injected replica IO/); }
  finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert.deepEqual(snapshots(config.directory), [first.snapshot]);
  assert.deepEqual(snapshots(config.replicaDirectory), [first.snapshot]);
  const pending = readdirSync(config.directory).filter(name => name.startsWith('.pending-'));
  assert.equal(pending.length, 1);
  assert(!readdirSync(config.replicaDirectory).some(name => name.startsWith('.pending-')));
  const key = readBackupKey(keyFile);
  try {
    await verifyEncryptedBackup(join(config.directory, first.snapshot), key);
    await verifyEncryptedBackup(join(config.directory, pending[0]!), key);
  }
  finally { key.fill(0); }
});

test('key rotation never prunes backups encrypted under the old key', async t => {
  const { root, keyFile, config, snapshots } = fixture(t);
  const first = await runBackupJob(config, keyFile);
  const nextKey = createBackupKey(join(root, 'new-key'));
  assert.equal((await runBackupJob(config, nextKey)).status, 'warning');
  assert.equal(snapshots(config.directory).length, 2);
  const oldKey = readBackupKey(keyFile);
  try { await verifyEncryptedBackup(join(config.replicaDirectory, first.snapshot), oldKey); }
  finally { oldKey.fill(0); }
});

test('clock moving backwards cannot prune the newly verified backup', async t => {
  const { keyFile, config, snapshots } = fixture(t);
  await runBackupJob(config, keyFile);
  const second = await runBackupJob(config, keyFile);
  t.mock.timers.enable({ apis: ['Date'], now: new Date('2020-01-01T00:00:00.000Z') });
  const current = await runBackupJob(config, keyFile);
  t.mock.timers.reset();
  for (const root of [config.directory, config.replicaDirectory]) {
    assert.deepEqual(snapshots(root), [current.snapshot, second.snapshot].sort());
  }
});

test('real CLI reads relative config paths and reports redacted success/failure with nonzero exit', async t => {
  const { root, keyFile, config } = fixture(t);
  const file = join(root, 'job.json');
  writeFileSync(file, JSON.stringify({ database: 'source.sqlite', directory: 'local', replicaDirectory: 'replica', keep: 2 }));
  assert.deepEqual(readBackupJobConfig(file), config);
  const cli = fileURLToPath(new URL('../tool/backup-job.ts', import.meta.url));
  function run(key: string, ...options: string[]) {
    const result = spawnSync(process.execPath, ['--import', 'tsx', cli, file, ...options], {
      cwd: fileURLToPath(new URL('../', import.meta.url)), env: { ...process.env, BACKUP_KEY_FILE: key }, encoding: 'utf8', timeout: 30000, windowsHide: true });
    assert.ifError(result.error);
    assert(!(result.stdout + result.stderr).includes(root));
    assert(!(result.stdout + result.stderr).includes(readFileSync(keyFile).toString('hex')));
    return result;
  }
  const result = run(keyFile);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).event, 'database_backup_job_completed');
  const damaged = join(config.directory, JSON.parse(result.stdout).snapshot, 'database.enc');
  const bytes = readFileSync(damaged); bytes[40] = bytes[40]! ^ 1; writeFileSync(damaged, bytes);
  const warning = run(keyFile, '--verify-all');
  assert.equal(warning.status, 2, warning.stderr);
  assert.equal(JSON.parse(warning.stdout).status, 'warning');
  assert.equal(JSON.parse(warning.stdout).copies, 2);
  assert.equal(run('').status, 1);
  writeFileSync(file, JSON.stringify({ ...config, keep: 0 }));
  assert.equal(run(keyFile).status, 1);
  assert(!existsSync(join(config.directory, '.haven-backup-job.lock')));
});

test('default job does not decrypt old database payloads; explicit verification detects and remembers corruption', async t => {
  const { keyFile, config } = fixture(t);
  const first = await runBackupJob(config, keyFile);
  const path = join(config.directory, first.snapshot, 'database.enc');
  const bytes = readFileSync(path); bytes[40] = bytes[40]! ^ 1; writeFileSync(path, bytes);
  assert.equal((await runBackupJob(config, keyFile)).status, 'ok');
  const checked = await runBackupJob(config, keyFile, { verifyAll: true });
  assert.equal(checked.status, 'warning');
  assert.equal(checked.invalidSnapshots, 1);
  assert.deepEqual(readFileSync(path), bytes);
  const next = await runBackupJob(config, keyFile);
  assert.equal(next.status, 'warning');
  assert.deepEqual(readFileSync(path), bytes);
});

test('failure releasing the first backup lock still releases the second lock', async t => {
  const { keyFile, config } = fixture(t);
  const releaseOrder = [config.directory, config.replicaDirectory].sort().reverse().map(root => join(root, '.haven-backup-job.lock'));
  const unlink = fs.unlinkSync;
  const fault = t.mock.method(fs, 'unlinkSync', (path: fs.PathLike) => {
    if (String(path) === releaseOrder[0]) throw new Error('injected first release failure');
    return unlink(path);
  });
  syncBuiltinESMExports();
  try { await assert.rejects(runBackupJob(config, keyFile), /已尝试释放全部锁/); }
  finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert(existsSync(releaseOrder[0]!));
  assert(!existsSync(releaseOrder[1]!));
});
