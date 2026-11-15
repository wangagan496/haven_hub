import { writeSync } from 'node:fs';
import type { Server } from 'node:http';
import { projectRuntimeEvent, type RuntimeLog } from './runtime-log.js';

type LifecycleEvent = 'server_config_failed' | 'server_start_failed' | 'server_listen_failed' | 'server_started'
  | 'server_stopping' | 'server_drained' | 'server_stopped' | 'server_shutdown_failed' | 'server_shutdown_timeout'
  | 'process_uncaught_exception' | 'process_unhandled_rejection';

/** No exception/configuration values enter this path; synchronous stderr avoids recursive stream errors. */
export function reportProcessEvent(event: LifecycleEvent) {
  try { writeSync(2, JSON.stringify(projectRuntimeEvent({ event })) + '\n'); }
  catch { /* Do not turn failure reporting into another uncaught exception. */ }
}

export function manageServerLifecycle(server: Server, resources: {
  stopBackgroundTasks?: () => Promise<void>;
  closeResources: () => void;
  runtimeLog?: RuntimeLog;
}, timeoutMs = 5000) {
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000) throw new Error('关闭等待时间无效');
  let shutdownPromise: Promise<void> | undefined;
  let complete: (() => void) | undefined;
  let deadline: ReturnType<typeof setTimeout> | undefined;
  let finished = false;
  let failed = false;
  let fatalRecorded = false;
  const record = (event: LifecycleEvent) => {
    resources.runtimeLog?.write({ event });
    reportProcessEvent(event);
  };
  const signal = () => { void shutdown(); };
  const fatal = (event: 'process_uncaught_exception' | 'process_unhandled_rejection') => {
    failed = true;
    if (!fatalRecorded) { fatalRecorded = true; record(event); }
    void shutdown(true);
  };
  const uncaught = () => fatal('process_uncaught_exception');
  const rejection = () => fatal('process_unhandled_rejection');
  const listenError = () => { record('server_listen_failed'); void shutdown(true); };
  const listening = () => { if (!shutdownPromise) record('server_started'); };
  const dispose = () => {
    process.off('SIGINT', signal); process.off('SIGTERM', signal);
    process.off('uncaughtException', uncaught); process.off('unhandledRejection', rejection);
    server.off('error', listenError); server.off('listening', listening);
  };

  const finish = (timedOut: boolean) => {
    if (finished) return;
    finished = true;
    clearTimeout(deadline);
    if (timedOut) {
      failed = true;
      record('server_shutdown_timeout');
      try { server.closeAllConnections(); } catch { /* Exit below remains nonzero. */ }
      // Do not close the database under still-running work. Process termination releases it.
    } else {
      if (!failed) record('server_drained');
      try { resources.closeResources(); } catch { failed = true; }
    }
    resources.runtimeLog?.close();
    failed ||= resources.runtimeLog?.failed === true;
    // The final outcome is stderr-only: the application-owned log is already closed.
    reportProcessEvent(failed ? 'server_shutdown_failed' : 'server_stopped');
    dispose();
    complete?.();
    process.exit(failed ? 1 : 0);
  };

  function shutdown(asFailure = false): Promise<void> {
    failed ||= asFailure;
    if (shutdownPromise) return shutdownPromise;
    shutdownPromise = new Promise<void>(resolve => { complete = resolve; });
    record('server_stopping');
    // Keep this timer referenced: a pending Promise alone cannot keep Node alive for cleanup.
    deadline = setTimeout(() => finish(true), timeoutMs);
    const httpClosed = new Promise<void>((resolve, reject) => {
      try {
        server.close(error => {
          if (error && (error as NodeJS.ErrnoException).code !== 'ERR_SERVER_NOT_RUNNING') reject(error);
          else resolve();
        });
        server.closeIdleConnections();
      } catch (error) { reject(error); }
    });
    let backgroundStopped: Promise<void>;
    try { backgroundStopped = resources.stopBackgroundTasks?.() ?? Promise.resolve(); }
    catch (error) { backgroundStopped = Promise.reject(error); }
    void Promise.allSettled([httpClosed, backgroundStopped]).then(results => {
      if (finished) return;
      failed ||= results.some(result => result.status === 'rejected');
      finish(false);
    });
    return shutdownPromise;
  }

  process.on('SIGINT', signal); process.on('SIGTERM', signal);
  process.on('uncaughtException', uncaught); process.on('unhandledRejection', rejection);
  server.on('error', listenError); server.on('listening', listening);
  return { shutdown };
}
