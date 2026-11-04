import { backup, DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { copyFileSync, constants, createReadStream, existsSync, lstatSync, mkdirSync, readFileSync, unlinkSync, writeFileSync, rmdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { userInfo } from 'node:os';
import { join, resolve } from 'node:path';
import { z } from 'zod';

const fileName = 'database.sqlite';
const manifestName = 'manifest.json';
const digest = z.string().regex(/^[a-f0-9]{64}$/);
export const manifestSchema = z.object({
  format: z.literal(1), startedAt: z.iso.datetime(), completedAt: z.iso.datetime(),
  schemaVersion: z.number().int().min(1), databaseSha256: digest,
  tables: z.record(z.string(), z.object({ rows: z.number().int().nonnegative(), sha256: digest }).strict()),
}).strict();
export type BackupManifest = z.infer<typeof manifestSchema>;

async function sha256(path: string) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}

function regularFile(path: string) {
  const entry = lstatSync(path);
  if (!entry.isFile() || entry.isSymbolicLink()) throw new Error('备份文件必须是普通文件');
}

function inventory(path: string) {
  regularFile(path);
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    if (db.prepare('PRAGMA integrity_check').all().some(row => row.integrity_check !== 'ok')) throw new Error('数据库完整性检查失败');
    if (db.prepare('PRAGMA foreign_key_check').all().length) throw new Error('数据库关联完整性检查失败');
    const tables: BackupManifest['tables'] = {};
    for (const row of db.prepare("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name").all()) {
      const table = String(row.name);
      // Names come from SQLite metadata, and are quoted as identifiers, never SQL fragments.
      const quoted = '"' + table.replaceAll('"', '""') + '"';
      const hash = createHash('sha256');
      let rows = 0;
      for (const record of db.prepare(`SELECT * FROM ${quoted} ORDER BY rowid`).iterate()) {
        hash.update(JSON.stringify(record, (_key, value: unknown) => value instanceof Uint8Array
          ? { bytes: Buffer.from(value).toString('hex') } : typeof value === 'bigint' ? { bigint: String(value) } : value));
        hash.update('\n'); rows++;
      }
      tables[table] = { rows, sha256: hash.digest('hex') };
    }
    return { schemaVersion: Number(db.prepare('PRAGMA user_version').get()!.user_version), tables };
  } finally { db.close(); }
}

export function createPrivateDirectory(path: string) {
  mkdirSync(path, { mode: 0o700 }); // Existing destinations are never overwritten or reused.
  if (process.platform === 'win32') {
    const account = process.env.USERDOMAIN ? `${process.env.USERDOMAIN}\\${userInfo().username}` : userInfo().username;
    try {
      execFileSync('icacls.exe', [path, '/inheritance:r', '/grant:r', `${account}:(OI)(CI)F`, '*S-1-5-18:(OI)(CI)F'], { stdio: 'pipe', windowsHide: true });
    } catch {
      rmdirSync(path);
      throw new Error('无法限制备份目录权限，尚未写入任何数据');
    }
  }
}

export function cleanupCreatedDirectory(directory: string) {
  // Only known files in the directory created by this operation; never recursive deletion.
  for (const name of [manifestName, fileName, `${fileName}-wal`, `${fileName}-shm`, `${fileName}-journal`]) {
    const path = join(directory, name);
    if (existsSync(path)) unlinkSync(path);
  }
  rmdirSync(directory);
}

/** SQLite online backup includes committed WAL pages; never copy a live DB file. */
export async function createBackup(sourcePath: string, destination: string): Promise<BackupManifest> {
  const source = resolve(sourcePath), target = resolve(destination);
  regularFile(source);
  const db = new DatabaseSync(source, { readOnly: true });
  let created = false;
  const startedAt = new Date().toISOString();
  try {
    createPrivateDirectory(target); created = true;
    const file = join(target, fileName);
    await backup(db, file);
    const manifest: BackupManifest = { format: 1, startedAt, completedAt: new Date().toISOString(),
      ...inventory(file), databaseSha256: await sha256(file) };
    manifestSchema.parse(manifest);
    writeFileSync(join(target, manifestName), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    await verifyBackup(target);
    return manifest;
  } catch (error) {
    if (created) cleanupCreatedDirectory(target);
    throw error;
  } finally { db.close(); }
}

export async function verifyBackup(directory: string): Promise<BackupManifest> {
  const file = join(resolve(directory), fileName), metadata = join(resolve(directory), manifestName);
  regularFile(metadata); regularFile(file);
  const manifest = manifestSchema.parse(JSON.parse(readFileSync(metadata, 'utf8')));
  if (await sha256(file) !== manifest.databaseSha256) throw new Error('备份文件校验失败，数据可能已损坏或变更');
  const actual = inventory(file);
  if (actual.schemaVersion !== manifest.schemaVersion || JSON.stringify(actual.tables) !== JSON.stringify(manifest.tables)) {
    throw new Error('备份记录清单与数据库不一致');
  }
  return manifest;
}

/** Restore into a fresh directory only; switching a running service is a separate, stopped-write operation. */
export async function restoreBackup(sourceDirectory: string, destination: string): Promise<BackupManifest> {
  const source = resolve(sourceDirectory), target = resolve(destination);
  const manifest = await verifyBackup(source);
  createPrivateDirectory(target);
  try {
    copyFileSync(join(source, fileName), join(target, fileName), constants.COPYFILE_EXCL);
    writeFileSync(join(target, manifestName), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    return await verifyBackup(target);
  } catch (error) {
    cleanupCreatedDirectory(target);
    throw error;
  }
}
