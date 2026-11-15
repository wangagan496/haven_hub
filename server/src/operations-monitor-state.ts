import { lstatSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { z } from 'zod';

const timestamp = z.iso.datetime().refine(value => new Date(value).toISOString() === value);
const sequence = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
export const collectorLockSchema = z.object({ runId: z.uuid(), pid: sequence,
  version: z.literal(1).optional(), startedAt: timestamp.optional() }).strict();
export const monitorObservationSchema = z.object({
  status: z.enum(['ok', 'alert', 'unavailable', 'maintenance', 'insufficient-data']),
  reasons: z.array(z.enum(['server_error_rate', 'request_latency', 'auth_rejected', 'requests_aborted',
    'push_due', 'push_overdue', 'push_stopped', 'push_expired_leases', 'push_unconfigured', 'push_invalid_state',
    'background_failures', 'probe_failed', 'maintenance_mode', 'credential_file_unavailable'])).max(16),
});
export const collectorReceiptSchema = z.object({
  version: z.literal(1), fingerprint: z.string().min(1).max(64),
  runId: z.uuid(), pid: sequence, seq: sequence, startedAt: timestamp, at: timestamp,
  event: z.enum(['collector_started', 'sample', 'collector_stopped']),
  clockRollback: z.boolean(),
  sample: monitorObservationSchema.extend({ seq: sequence, at: timestamp }).strict().nullable(),
}).strict();
export type CollectorReceipt = z.infer<typeof collectorReceiptSchema>;

const collectorFiles = new Set(['monitor.sqlite', 'monitor.sqlite-wal', 'monitor.sqlite-shm',
  'collector.lock', 'collector-status.json', 'collector-status.pending']);

export function validateCollectorDirectory(directory: string) {
  const stat = lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('Invalid collector directory');
  for (const name of readdirSync(directory)) {
    const entry = lstatSync(join(directory, name));
    const recoveryClaim = /^collector\.lock(?:\.reclaim-[a-f0-9]{16})+$/.test(name);
    if ((!collectorFiles.has(name) && !recoveryClaim) || !entry.isFile() || entry.isSymbolicLink()) throw new Error('Invalid collector file');
  }
}
