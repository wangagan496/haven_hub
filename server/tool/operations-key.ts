import { createOperationsKey } from '../src/operations-key.js';

try {
  const [directory, expiresAt, ...extra] = process.argv.slice(2);
  if (!directory || !expiresAt || extra.length) throw new Error('Invalid arguments');
  const key = createOperationsKey(directory, expiresAt);
  process.stdout.write(JSON.stringify({ event: 'operations_key_created', ...key }) + '\n');
} catch {
  process.stderr.write(JSON.stringify({ event: 'operations_key_create_failed',
    message: '请指定全新的绝对目录和未来UTC到期时间，并检查父目录及权限；不会覆盖现有凭证' }) + '\n');
  process.exitCode = 1;
}
