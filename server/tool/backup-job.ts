import { readBackupJobConfig, runBackupJob } from '../src/backup-job.js';
import { ProcessLockOccupiedError } from '../src/process-lock.js';

try {
  const [configFile, option, ...extra] = process.argv.slice(2);
  if (!configFile || extra.length || (option !== undefined && option !== '--verify-all') || !process.env.BACKUP_KEY_FILE) throw new Error('备份任务配置不完整');
  const result = await runBackupJob(readBackupJobConfig(configFile), process.env.BACKUP_KEY_FILE, { verifyAll: option === '--verify-all' });
  process.stdout.write(JSON.stringify(result) + '\n');
  if (result.status === 'warning') process.exitCode = 2;
} catch (error) {
  // Do not expose configuration paths, database content, raw IO/SQL errors or key material.
  process.stderr.write(JSON.stringify({ event: 'database_backup_job_failed',
    message: error instanceof ProcessLockOccupiedError ? error.message : '备份任务失败；请核对配置、挂载、密钥、权限、锁和备份完整性，失败任务不保证已完成保留清理' }) + '\n');
  process.exitCode = 1;
}
