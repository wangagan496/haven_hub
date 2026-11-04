import { createHash, randomUUID } from 'node:crypto';
import { constants, copyFileSync, existsSync, lstatSync, readFileSync, readdirSync, realpathSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { z } from 'zod';
import { createPrivateDirectory } from './backup.js';
import { createEncryptedBackup, readBackupKey, readEncryptedBackupManifest, verifyEncryptedBackup } from './encrypted-backup.js';
import { acquireProcessLock } from './process-lock.js';

const configSchema = z.object({
  database: z.string().min(1), directory: z.string().min(1), replicaDirectory: z.string().min(1),
  // Explicit policy: do not turn the suggested production retention period into a default.
  keep: z.number().int().min(2).max(10000),
}).strict();
export type BackupJobConfig = z.infer<typeof configSchema>;
const files = ['database.enc', 'manifest.enc'] as const;
const snapshotName = /^snapshot-\d{17}-[a-f0-9-]{36}$/;
const markerName = '.haven-backup-job.json';
const lockName = '.haven-backup-job.lock';

export function readBackupJobConfig(file: string): BackupJobConfig {
  const path = resolve(file), base = dirname(path);
  const config = configSchema.parse(JSON.parse(readFileSync(path, 'utf8')));
  return { ...config, database: resolve(base, config.database), directory: resolve(base, config.directory), replicaDirectory: resolve(base, config.replicaDirectory) };
}

function within(parent: string, child: string) {
  const part = relative(parent, child);
  return part === '' || (!isAbsolute(part) && part !== '..' && !part.startsWith(`..${sep}`));
}

function ordinaryDirectory(path: string) {
  const stat = lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('备份目录必须是普通目录');
}

function rootPath(path: string) {
  const absolute = resolve(path);
  // Resolve an existing parent too, so aliases cannot bypass containment checks.
  const canonical = existsSync(absolute) ? realpathSync(absolute) : join(realpathSync(dirname(absolute)), relative(dirname(absolute), absolute));
  if (existsSync(absolute)) ordinaryDirectory(absolute);
  return canonical;
}

function bindRoot(directory: string, identity: string) {
  if (!existsSync(directory)) createPrivateDirectory(directory);
  ordinaryDirectory(directory);
  const marker = join(directory, markerName);
  if (!existsSync(marker)) {
    if (readdirSync(directory).length) throw new Error('只能初始化空的专用备份目录');
    writeFileSync(marker, JSON.stringify({ format: 1, identity }) + '\n', { flag: 'wx', mode: 0o600 });
  }
  const stat = lstatSync(marker);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 1024) throw new Error('备份目录标识无效');
  const saved = z.object({ format: z.literal(1), identity: z.literal(identity) }).strict().parse(JSON.parse(readFileSync(marker, 'utf8')));
  return saved;
}

function acquireLock(directory: string) {
  const path = join(directory, lockName);
  const lock = acquireProcessLock(path);
  if (lock.recovered) process.stderr.write('{"event":"backup_lock_recovered"}\n');
  return lock;
}

function removeSnapshot(directory: string) {
  // No recursive deletion: unrecognised files, directories and links are never traversed.
  for (const file of files) unlinkSync(join(directory, file));
  rmdirSync(directory);
}

async function expiredSnapshots(directory: string, key: Buffer, keep: number, current: string, verifyAll: boolean) {
  const snapshots: { path: string; completedAt: string }[] = [];
  const invalidFile = join(directory, '.haven-backup-invalid.json');
  const knownInvalid = new Set<string>();
  if (existsSync(invalidFile)) {
    const stat = lstatSync(invalidFile);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 2 * 1024 * 1024) throw new Error('备份异常清单无效');
    for (const name of z.array(z.string().regex(snapshotName)).max(10000).parse(JSON.parse(readFileSync(invalidFile, 'utf8')))) knownInvalid.add(name);
  }
  const invalid: string[] = [];
  for (const name of readdirSync(directory)) {
    if (!snapshotName.test(name)) continue;
    const path = join(directory, name);
    try {
      if (!verifyAll && knownInvalid.has(name)) throw new Error('已标记异常');
      ordinaryDirectory(path);
      const entries = readdirSync(path).sort();
      if (JSON.stringify(entries) !== JSON.stringify([...files].sort())) throw new Error('备份包含未知文件');
      for (const file of files) {
        const stat = lstatSync(join(path, file));
        if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 36) throw new Error('备份文件无效');
      }
      const manifest = verifyAll && path !== current
        ? await verifyEncryptedBackup(path, key) : readEncryptedBackupManifest(path, key);
      snapshots.push({ path, completedAt: manifest.completedAt });
    } catch { invalid.push(name); }
  }
  const pending = join(directory, `.invalid-${randomUUID()}.pending`);
  try {
    writeFileSync(pending, JSON.stringify(invalid) + '\n', { flag: 'wx', mode: 0o600 });
    renameSync(pending, invalidFile);
  } finally { if (existsSync(pending)) unlinkSync(pending); }
  // Always protect this run even if the host clock moved backwards.
  snapshots.sort((a, b) => a.path === current ? -1 : b.path === current ? 1 : b.completedAt.localeCompare(a.completedAt) || b.path.localeCompare(a.path));
  return { expired: snapshots.slice(keep).map(snapshot => snapshot.path), invalid };
}

/** One invocation for an external scheduler; no background timer and no active DB replacement. */
export async function runBackupJob(input: BackupJobConfig, keyFile: string, options: { verifyAll?: boolean } = {}) {
  const config = configSchema.parse(input);
  const keyEntry = lstatSync(keyFile);
  if (!keyEntry.isFile() || keyEntry.isSymbolicLink()) throw new Error('备份密钥文件必须是普通文件');
  const source = realpathSync(config.database), keyPath = realpathSync(keyFile);
  const local = rootPath(config.directory), replica = rootPath(config.replicaDirectory);
  if (within(local, replica) || within(replica, local) ||
      [local, replica].some(root => within(root, source) || within(root, keyPath))) {
    throw new Error('数据库、密钥和两份备份必须分离');
  }
  // Bind both roots to this source path, preventing accidental reuse for another database.
  const identity = createHash('sha256').update(source).digest('hex');
  bindRoot(local, identity); bindRoot(replica, identity);
  const locks: ReturnType<typeof acquireProcessLock>[] = [];
  let key: Buffer | undefined;
  const id = randomUUID(), name = `snapshot-${new Date().toISOString().replace(/\D/g, '')}-${id}`;
  const stagedLocal = join(local, `.pending-${id}`), stagedReplica = join(replica, `.pending-${id}`);
  const destination = join(local, name), replicaDestination = join(replica, name);
  let replicaCreated = false;
  try {
    for (const root of [local, replica].sort()) locks.push(acquireLock(root));
    key = readBackupKey(keyPath);
    const manifest = await createEncryptedBackup(source, stagedLocal, key);
    try {
      createPrivateDirectory(stagedReplica); replicaCreated = true;
      for (const file of files) copyFileSync(join(stagedLocal, file), join(stagedReplica, file), constants.COPYFILE_EXCL);
      const verified = await verifyEncryptedBackup(stagedReplica, key);
      if (verified.databaseSha256 !== manifest.databaseSha256) throw new Error('副本校验不一致');
    } catch (error) {
      if (replicaCreated) {
        for (const file of files) if (existsSync(join(stagedReplica, file))) unlinkSync(join(stagedReplica, file));
        rmdirSync(stagedReplica);
      }
      // Keep the verified local staging snapshot for manual recovery; never prune after failure.
      throw error;
    }
    renameSync(stagedLocal, destination);
    renameSync(stagedReplica, replicaDestination);
    const localPlan = await expiredSnapshots(local, key, config.keep, destination, options.verifyAll === true);
    const replicaPlan = await expiredSnapshots(replica, key, config.keep, replicaDestination, options.verifyAll === true);
    for (const path of [...localPlan.expired, ...replicaPlan.expired]) removeSnapshot(path);
    const invalidSnapshots = localPlan.invalid.length + replicaPlan.invalid.length;
    return { event: invalidSnapshots ? 'database_backup_job_completed_with_warnings' : 'database_backup_job_completed',
      status: invalidSnapshots ? 'warning' : 'ok', invalidSnapshots,
      snapshot: name, schemaVersion: manifest.schemaVersion,
      completedAt: manifest.completedAt, copies: 2, removed: localPlan.expired.length + replicaPlan.expired.length };
  } finally {
    key?.fill(0);
    const errors: unknown[] = [];
    for (const lock of locks.reverse()) {
      try { lock.release(); } catch (error) { errors.push(error); }
    }
    if (errors.length) throw new AggregateError(errors, '备份锁释放失败，已尝试释放全部锁');
  }
}
