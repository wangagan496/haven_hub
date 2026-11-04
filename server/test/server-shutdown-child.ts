import { writeFileSync, readdirSync, truncateSync } from 'node:fs';
import { join } from 'node:path';
import { Notifications } from '../src/notifications.js';
import { Store } from '../src/database.js';

// Exercise the real compiled entry point with a controlled in-flight background operation.
const report = { stopCalls: 0, stopFinished: false, databaseCloseCalls: 0, databaseClosedBeforeStop: false };
const stop = Notifications.prototype.stop;
Notifications.prototype.stop = function () {
  report.stopCalls++;
  if (process.env.TEST_STOP_MODE === 'throw') throw new Error('private-stop-failure');
  if (process.env.TEST_STOP_MODE === 'hang') return new Promise<void>(() => {});
  return new Promise<void>(resolve => setTimeout(resolve, 150)).then(async () => {
    await stop.call(this);
    report.stopFinished = true;
  });
};
const close = Store.prototype.close;
Store.prototype.close = function () {
  report.databaseCloseCalls++;
  report.databaseClosedBeforeStop ||= !report.stopFinished;
  if (process.env.TEST_CLOSE_MODE === 'throw') throw new Error('private-close-failure');
  return close.call(this);
};
process.on('exit', () => writeFileSync(process.argv[2]!, JSON.stringify(report)));
await import('../src/main.js');
if (process.exitCode) process.disconnect?.();
else process.on('message', message => {
  if (message === 'stop') process.emit('SIGTERM');
  if (message === 'stop-twice') { process.emit('SIGTERM'); process.emit('SIGINT'); }
  if (message === 'stop-disconnect') { process.emit('SIGTERM'); process.disconnect?.(); }
  if (message === 'uncaught') setImmediate(() => { throw new Error('private-uncaught-failure'); });
  if (message === 'rejection') void Promise.reject(new Error('private-rejection-failure'));
  if (message === 'stop-then-fatal') {
    process.emit('SIGTERM');
    setImmediate(() => { throw new Error('private-late-failure'); });
  }
  if (message === 'damage-log-stop') {
    const directory = process.env.RUNTIME_LOG_DIRECTORY!;
    const file = readdirSync(directory).filter(name => name.endsWith('.jsonl')).sort().at(-1)!;
    truncateSync(join(directory, file), 0);
    process.emit('SIGTERM');
  }
});
