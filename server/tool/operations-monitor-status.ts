import { readOperationsMonitorConfig } from '../src/operations-monitor.js';
import { checkOperationsMonitor } from '../src/operations-monitor-status.js';

try {
  const [path, ...extra] = process.argv.slice(2);
  if (!path || extra.length) throw new Error('Invalid arguments');
  const result = checkOperationsMonitor(readOperationsMonitorConfig(path));
  process.stdout.write(JSON.stringify(result) + '\n');
  process.exitCode = result.exitCode;
} catch {
  process.stdout.write(JSON.stringify({ status: 'unavailable', reasons: ['status_unavailable'], exitCode: 1 }) + '\n');
  process.exitCode = 1;
}
