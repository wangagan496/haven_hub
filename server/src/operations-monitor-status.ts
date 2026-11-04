import { lstatSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { readOperationsJson } from './operations-credentials.js';
import { readOperationsCheckConfig } from './operations-check.js';
import { operationsMonitorConfigSchema, operationsMonitorFingerprint, type OperationsMonitorConfig } from './operations-monitor.js';
import { collectorLockSchema, collectorReceiptSchema, validateCollectorDirectory, type CollectorReceipt } from './operations-monitor-state.js';

function readLock(directory: string) {
  try { return collectorLockSchema.parse(readOperationsJson(join(directory, 'collector.lock'), 1024)); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
    throw error;
  }
}

export type CollectorStatus = 'fresh' | 'starting' | 'stopped' | 'stale' | 'unavailable';
type StatusReason = 'awaiting_first_sample' | 'collector_stopped' | 'sample_overdue' | 'startup_overdue'
  | 'lock_missing' | 'identity_mismatch' | 'snapshot_changed' | 'clock_invalid' | 'configuration_changed'
  | 'status_unavailable';

/** Reads only bounded files: no HTTP, credentials, SQLite connection, process signal or lock acquisition. */
export function checkOperationsMonitor(rawConfig: OperationsMonitorConfig, now?: number) {
  const result = (status: CollectorStatus, reason: StatusReason | null, exitCode: 0 | 1 | 2 | 3,
    details?: { ageMs: number; deadlineMs: number; sample: CollectorReceipt['sample'] }) => ({
    status, reasons: reason ? [reason] : [], exitCode,
    ...(details ? { ageMs: details.ageMs, deadlineMs: details.deadlineMs,
      lastSample: details.sample ? { at: details.sample.at, status: details.sample.status, reasons: details.sample.reasons } : null } : {}),
  });
  try {
    const config = operationsMonitorConfigSchema.parse(rawConfig);
    const check = readOperationsCheckConfig(config.checkConfigFile);
    if (check.authentication !== 'operations-key') throw new Error('Invalid authentication');
    const directory = resolve(config.directory);
    validateCollectorDirectory(directory);
    // A receipt must belong to an existing journal, but opening SQLite here would create WAL sidecars.
    if (!lstatSync(join(directory, 'monitor.sqlite')).isFile()) throw new Error('Journal missing');
    const before = readLock(directory);
    const receipt = collectorReceiptSchema.parse(readOperationsJson(join(directory, 'collector-status.json'), 4096));
    const after = readLock(directory);
    // Capture the real clock after the snapshot: a concurrent publisher can legitimately advance it while we read.
    const checkedAt = now ?? Date.now();
    if (!Number.isSafeInteger(checkedAt) || checkedAt < 0) throw new Error('Invalid time');
    if (JSON.stringify(before) !== JSON.stringify(after)) return result('unavailable', 'snapshot_changed', 3);
    if (receipt.fingerprint !== operationsMonitorFingerprint(config, check)) {
      return result('unavailable', 'configuration_changed', 1);
    }
    const started = Date.parse(receipt.startedAt);
    const latest = Date.parse(receipt.at);
    const sampled = receipt.sample ? Date.parse(receipt.sample.at) : null;
    if (receipt.clockRollback || started > checkedAt || latest > checkedAt || latest < started
      || (sampled !== null && (sampled < started || sampled > latest || receipt.sample!.seq > receipt.seq))
      || (receipt.event === 'collector_started' && receipt.sample !== null)
      || (receipt.event === 'sample' && (!receipt.sample || receipt.sample.seq !== receipt.seq || sampled !== latest))) {
      return result('unavailable', 'clock_invalid', 1);
    }
    if (after && (after.runId !== receipt.runId || after.pid !== receipt.pid)) {
      return result('unavailable', 'identity_mismatch', 1);
    }
    // Three sequential HTTP deadlines plus a fixed ten-second scheduling/publication allowance.
    const startupMs = check.timeoutMs * 3 + 10000;
    const deadlineMs = sampled === null ? startupMs : config.intervalSeconds * 1000 + startupMs;
    const details = { ageMs: checkedAt - (sampled ?? started), deadlineMs, sample: receipt.sample };
    if (receipt.event === 'collector_stopped') return result('stopped', 'collector_stopped', 2, details);
    if (!after) return result('unavailable', 'lock_missing', 2, details);
    if (details.ageMs > deadlineMs) return result('stale', sampled === null ? 'startup_overdue' : 'sample_overdue', 2, details);
    if (sampled === null) return result('starting', 'awaiting_first_sample', 3, details);
    // Freshness is independent of the service result and is not proof that this PID is alive.
    return result('fresh', null, 0, details);
  } catch { return result('unavailable', 'status_unavailable', 1); }
}
