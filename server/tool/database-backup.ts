import { resolve } from 'node:path';
import { createBackup, restoreBackup, verifyBackup } from '../src/backup.js';
import { createBackupKey, createEncryptedBackup, readBackupKey, restoreEncryptedBackup, verifyEncryptedBackup } from '../src/encrypted-backup.js';

const [operation, source, destination, ...extra] = process.argv.slice(2);
let key: Buffer | undefined;
try {
  const onePath = ['verify', 'verify-encrypted', 'keygen'].includes(operation ?? '');
  if (!source || extra.length || !['create', 'verify', 'restore', 'keygen', 'create-encrypted', 'verify-encrypted', 'restore-encrypted'].includes(operation ?? '') ||
      (onePath ? Boolean(destination) : !destination)) {
    throw new Error('备份命令或路径参数不正确');
  }
  if (operation === 'keygen') {
    const file = createBackupKey(source);
    process.stdout.write(JSON.stringify({ event: 'database_backup_key_created', keyFile: file }) + '\n');
  } else {
    const encrypted = operation!.endsWith('-encrypted');
    if (encrypted) {
      if (!process.env.BACKUP_KEY_FILE) throw new Error('缺少备份密钥文件配置');
      key = readBackupKey(process.env.BACKUP_KEY_FILE);
    }
    const manifest = operation === 'create-encrypted' ? await createEncryptedBackup(source, destination!, key!) :
      operation === 'verify-encrypted' ? await verifyEncryptedBackup(source, key!) :
      operation === 'restore-encrypted' ? await restoreEncryptedBackup(source, destination!, key!) :
      operation === 'create' ? await createBackup(source, destination!) :
      operation === 'restore' ? await restoreBackup(source, destination!) : await verifyBackup(source);
    process.stdout.write(JSON.stringify({ event: `database_${operation}_completed`,
      destination: resolve(destination ?? source), schemaVersion: manifest.schemaVersion,
      completedAt: manifest.completedAt, ...(encrypted ? { destinationEncrypted: operation !== 'restore-encrypted' } : { tables: manifest.tables }) }) + '\n');
  }
} catch (error) {
  // Paths and SQL errors can contain private values; stdout never contains DB contents or credentials.
  process.stderr.write(JSON.stringify({ event: 'database_backup_failed', type: error instanceof Error ? error.name : 'unknown',
    message: '备份操作失败，未覆盖已有目录；请核对命令、密钥文件配置、目录权限、备份完整性及数据库状态' }) + '\n');
  process.exitCode = 1;
} finally { key?.fill(0); }
