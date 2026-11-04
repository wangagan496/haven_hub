import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from 'node:crypto';
import { createWriteStream, existsSync, lstatSync, readFileSync, rmdirSync, unlinkSync, writeFileSync } from 'node:fs';
import { open } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { cleanupCreatedDirectory, createBackup, createPrivateDirectory, manifestSchema, verifyBackup, type BackupManifest } from './backup.js';

// v1 envelope: 8-byte magic, 12-byte random nonce, ciphertext, 16-byte GCM tag.
// Authenticate both the format header and the intended filename; never accept an algorithm from input.
const magic = Buffer.from('HAVENBK1');
const headerSize = 20, tagSize = 16;
const files = [['manifest.json', 'manifest.enc'], ['database.sqlite', 'database.enc']] as const;
const validateKey = (key: Buffer) => {
  if (!Buffer.isBuffer(key) || key.length !== 32) throw new Error('备份密钥必须是32字节随机密钥');
};
const scratchPath = (backup: string) => join(dirname(resolve(backup)), `.haven-backup-private-${process.pid}-${randomUUID()}`);

function removeEncryptedDirectory(directory: string) {
  for (const [, name] of files) {
    const file = join(directory, name);
    if (existsSync(file)) unlinkSync(file);
  }
  rmdirSync(directory);
}

/** Generates a binary key in a new private directory; callers must store it separately from backups. */
export function createBackupKey(destination: string) {
  const directory = resolve(destination);
  createPrivateDirectory(directory);
  const key = randomBytes(32), file = join(directory, 'backup.key');
  try { writeFileSync(file, key, { flag: 'wx', mode: 0o600 }); }
  catch (error) {
    if (existsSync(file)) unlinkSync(file);
    rmdirSync(directory); throw error;
  } finally { key.fill(0); }
  return file;
}

export function readBackupKey(path: string): Buffer {
  const entry = lstatSync(path);
  if (!entry.isFile() || entry.isSymbolicLink() || entry.size !== 32) throw new Error('备份密钥文件无效');
  const key = readFileSync(path);
  try { validateKey(key); return key; }
  catch (error) { key.fill(0); throw error; }
}

async function transformFile(source: string, target: string, name: string, key: Buffer, decrypt: boolean) {
  const entry = lstatSync(source);
  if (!entry.isFile() || entry.isSymbolicLink()) throw new Error('备份输入必须是普通文件');
  const input = await open(source, 'r');
  try {
    const stat = await input.stat();
    if (!stat.isFile() || !Number.isSafeInteger(stat.size)) throw new Error('备份文件无效');
    if (decrypt && stat.size <= headerSize + tagSize) throw new Error('加密备份不完整');
    const header = decrypt ? Buffer.alloc(headerSize) : Buffer.concat([magic, randomBytes(12)]);
    if (decrypt) {
      const read = await input.read(header, 0, headerSize, 0);
      if (read.bytesRead !== headerSize || !header.subarray(0, magic.length).equals(magic)) throw new Error('不支持的加密备份格式');
    }
    const nonce = header.subarray(magic.length);
    const aad = Buffer.concat([header, Buffer.from(name, 'utf8')]);
    if (decrypt) {
      const tag = Buffer.alloc(tagSize);
      if ((await input.read(tag, 0, tagSize, stat.size - tagSize)).bytesRead !== tagSize) throw new Error('加密备份不完整');
      const decipher = createDecipheriv('aes-256-gcm', key, nonce, { authTagLength: tagSize });
      decipher.setAAD(aad); decipher.setAuthTag(tag);
      // Plaintext stays inside this operation's private directory, is never opened as SQLite until
      // both tags validate, and is removed on authentication/IO/inventory failure.
      await pipeline(input.createReadStream({ start: headerSize, end: stat.size - tagSize - 1, autoClose: false }),
        decipher, createWriteStream(target, { flags: 'wx', mode: 0o600 }));
    } else {
      const cipher = createCipheriv('aes-256-gcm', key, nonce, { authTagLength: tagSize });
      cipher.setAAD(aad);
      async function* encrypted() {
        yield header;
        for await (const chunk of input.createReadStream({ autoClose: false })) yield cipher.update(chunk as Buffer);
        yield cipher.final(); yield cipher.getAuthTag();
      }
      await pipeline(Readable.from(encrypted()), createWriteStream(target, { flags: 'wx', mode: 0o600 }));
    }
  } finally { await input.close(); }
}

/** Online SQLite snapshot first, then stream-encrypt both files; output is independently verified. */
export async function createEncryptedBackup(source: string, destination: string, key: Buffer): Promise<BackupManifest> {
  validateKey(key);
  const target = resolve(destination), scratch = scratchPath(destination);
  createPrivateDirectory(target);
  let snapshotCreated = false;
  try {
    const manifest = await createBackup(source, scratch);
    snapshotCreated = true;
    for (const [plain, encrypted] of files) await transformFile(join(scratch, plain), join(target, encrypted), plain, key, false);
    // Read-back authenticates ciphertext and verifies its database against the encrypted manifest.
    const verified = await verifyEncryptedBackup(target, key);
    if (verified.databaseSha256 !== manifest.databaseSha256) throw new Error('加密备份回读不一致');
    return verified;
  } catch (error) {
    removeEncryptedDirectory(target); throw error;
  } finally {
    if (snapshotCreated) cleanupCreatedDirectory(scratch);
  }
}

/** No live database replacement; plaintext destination must be new, with private permissions. */
export async function restoreEncryptedBackup(source: string, destination: string, key: Buffer): Promise<BackupManifest> {
  validateKey(key);
  const target = resolve(destination);
  createPrivateDirectory(target);
  try {
    for (const [plain, encrypted] of files) await transformFile(join(resolve(source), encrypted), join(target, plain), plain, key, true);
    return await verifyBackup(target);
  } catch (error) {
    cleanupCreatedDirectory(target); throw error;
  }
}

/** Verification needs temporary private plaintext space, cleaned on success and failure. */
export async function verifyEncryptedBackup(source: string, key: Buffer): Promise<BackupManifest> {
  const scratch = scratchPath(source);
  // restore cleans only the directory it successfully created on failure. Do not inspect/remove
  // a colliding path here: it may belong to someone else when exclusive creation failed.
  const manifest = await restoreEncryptedBackup(source, scratch, key);
  cleanupCreatedDirectory(scratch);
  return manifest;
}

/** Read only authenticated, bounded metadata for retention; this is not a full database verification. */
export function readEncryptedBackupManifest(source: string, key: Buffer): BackupManifest {
  validateKey(key);
  const file = join(source, 'manifest.enc');
  const stat = lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= headerSize + tagSize || stat.size > 1024 * 1024)
    throw new Error('备份清单无效');
  const encrypted = readFileSync(file), header = encrypted.subarray(0, headerSize);
  if (!header.subarray(0, magic.length).equals(magic)) throw new Error('备份清单格式无效');
  const decipher = createDecipheriv('aes-256-gcm', key, header.subarray(magic.length), { authTagLength: tagSize });
  decipher.setAAD(Buffer.concat([header, Buffer.from('manifest.json')]));
  decipher.setAuthTag(encrypted.subarray(-tagSize));
  const plain = Buffer.concat([decipher.update(encrypted.subarray(headerSize, -tagSize)), decipher.final()]);
  try { return manifestSchema.parse(JSON.parse(plain.toString('utf8'))); }
  finally { plain.fill(0); }
}
