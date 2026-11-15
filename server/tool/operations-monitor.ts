import { readOperationsMonitorConfig, runOperationsMonitor } from '../src/operations-monitor.js';
import { ProcessLockOccupiedError } from '../src/process-lock.js';

const stop = new AbortController();
const shutdown = () => stop.abort();
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
try {
  const [path, option, count, ...extra] = process.argv.slice(2);
  if (!path || extra.length || (option !== undefined && (option !== '--cycles' || !/^\d+$/.test(count ?? '')))) {
    throw new Error('Invalid arguments');
  }
  await runOperationsMonitor(readOperationsMonitorConfig(path), { signal: stop.signal,
    ...(count !== undefined ? { cycles: Number(count) } : {}) });
} catch (error) {
  process.stderr.write(JSON.stringify({ event: 'collector_failed',
    message: error instanceof ProcessLockOccupiedError ? error.message : '持续监控已停止；请检查配置、专用目录、进程锁和日志写入状态，未确认原进程退出前不要清除锁' }) + '\n');
  process.exitCode = 1;
} finally {
  process.off('SIGINT', shutdown);
  process.off('SIGTERM', shutdown);
}
