import { dirname, resolve } from 'node:path';
import { z } from 'zod';
import { clientVersionPattern } from './client-compatibility.js';
import { operationsTokenPattern, readOperationsJson } from './operations-credentials.js';

const count = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const thresholdsSchema = z.object({
  minimumRequests: count.min(1), maxServerErrorRate: z.number().min(0).max(1),
  maxAuthRejected: count, maxAborted: count, maxP95Ms: z.number().int().min(1).max(10000),
  maxDue: count, maxDueDelayMs: count, maxStopped: count, maxExpiredLeases: count,
  maxUnconfigured: count, maxBackgroundFailures: count,
}).strict();

export const operationsCheckConfigSchema = z.object({
  // This local tool cannot send credentials to an external host.
  baseUrl: z.url().refine(value => {
    const url = new URL(value);
    return ['http:', 'https:'].includes(url.protocol) && ['127.0.0.1', '[::1]'].includes(url.hostname)
      && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/';
  }),
  tokenFile: z.string().min(1), clientVersion: z.string().regex(clientVersionPattern),
  authentication: z.enum(['admin-session', 'operations-key']).optional(),
  timeoutMs: z.number().int().min(100).max(30000), thresholds: thresholdsSchema,
}).strict();
export type OperationsCheckConfig = z.infer<typeof operationsCheckConfigSchema>;

const snapshotSchema = z.object({
  schemaVersion: z.literal(1), generatedAt: count,
  requests: z.object({
    scope: z.literal('single-process'), uptimeMs: count, windowMs: z.literal(600000), bucketMs: z.literal(10000),
    observedMs: count.max(600000), activeRequests: count, completed: count, serverErrors: count,
    rejected: count, authRejected: count, rateLimited: count, aborted: count,
    notificationSyncFailures: count, notificationStartupFailures: count, pushDispatchFailures: count,
    pushTransportFailures: count, smsSendFailures: count,
    serverErrorRate: z.number().min(0).max(1).nullable(),
    latency: z.object({ p95UpperBoundMs: count.nullable(),
      buckets: z.array(z.object({ upperBoundMs: count.nullable(), count }).strict()).length(9) }).strict(),
  }).strict(),
  push: z.object({ activeDeliveries: count, queued: count, failed: count, sending: count, accepted: count,
    unconfigured: count, expired: count, unknownStatus: count, stopped: count, expiredLeases: count,
    orphaned: count, due: count, oldestDueDelayMs: count.nullable() }).strict(),
}).strict();

export function readOperationsCheckConfig(path: string): OperationsCheckConfig {
  try {
    const config = operationsCheckConfigSchema.parse(readOperationsJson(path, 16384));
    return { ...config, tokenFile: resolve(dirname(resolve(path)), config.tokenFile) };
  } catch { throw new Error('运行检查配置无效'); }
}

export function readOperationsToken(path: string): string {
  try { return z.object({ token: z.string().regex(/^(ops_v1_)?[a-f0-9]{64}$/) }).strict().parse(readOperationsJson(path, 1024)).token; }
  catch { throw new Error('运行检查凭证文件无效'); }
}

async function fetchJson(url: string, config: OperationsCheckConfig, token?: string, signal?: AbortSignal): Promise<unknown> {
  const timeout = AbortSignal.timeout(config.timeoutMs);
  const response = await fetch(url, {
    redirect: 'error', signal: signal ? AbortSignal.any([timeout, signal]) : timeout,
    headers: { ...(config.authentication === 'operations-key' ? { 'X-Operations-Version': '1' }
      : { 'X-Client-Version': config.clientVersion, 'X-Client-Platform': 'admin-web' }),
      ...(token ? { Authorization: `Bearer ${token}` } : {}) },
  });
  if (!response.ok || !response.body) { await response.body?.cancel(); throw new Error('Probe rejected'); }
  const reader = response.body.getReader();
  let bytes = 0;
  const chunks: Uint8Array[] = [];
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 32768) throw new Error('Probe too large');
      chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { await reader.cancel(); reader.releaseLock(); }
}

export async function runOperationsCheck(rawConfig: OperationsCheckConfig, token: string, signal?: AbortSignal) {
  try {
    const config = operationsCheckConfigSchema.parse(rawConfig);
    const machine = config.authentication === 'operations-key';
    if (!(machine ? operationsTokenPattern : /^[a-f0-9]{64}$/).test(token)) throw new Error('Invalid token');
    const base = new URL(config.baseUrl).origin;
    const health = z.object({ code: z.literal(10000), data: z.object({
      mode: z.enum(['local-learning', 'sms-testing', 'production', 'maintenance']),
    }) }).parse(await fetchJson(`${base}/health`, config, undefined, signal));
    if (health.data.mode === 'maintenance') return { status: 'maintenance' as const, reasons: ['maintenance_mode'], exitCode: 3 };
    z.object({ code: z.literal(10000), data: z.object({ ready: z.literal(true) }) })
      .parse(await fetchJson(`${base}/ready`, config, undefined, signal));
    const { data } = z.object({ code: z.literal(10000), data: snapshotSchema })
      .parse(await fetchJson(`${base}${machine ? '/operations/snapshot' : '/management/operations'}`, config, token, signal));
    const { requests, push } = data;
    const limit = config.thresholds;
    const reasons: string[] = [];
    // Individual errors are still observable during warmup; ratios/percentiles need enough samples.
    if (requests.completed >= limit.minimumRequests) {
      if (requests.serverErrorRate === null || requests.serverErrorRate > limit.maxServerErrorRate) reasons.push('server_error_rate');
      if (requests.latency.p95UpperBoundMs === null || requests.latency.p95UpperBoundMs > limit.maxP95Ms) reasons.push('request_latency');
    }
    if (requests.authRejected > limit.maxAuthRejected) reasons.push('auth_rejected');
    if (requests.aborted > limit.maxAborted) reasons.push('requests_aborted');
    if (push.due > limit.maxDue) reasons.push('push_due');
    if (push.oldestDueDelayMs !== null && push.oldestDueDelayMs > limit.maxDueDelayMs) reasons.push('push_overdue');
    if (push.stopped > limit.maxStopped) reasons.push('push_stopped');
    if (push.expiredLeases > limit.maxExpiredLeases) reasons.push('push_expired_leases');
    if (push.unconfigured > limit.maxUnconfigured) reasons.push('push_unconfigured');
    if (push.orphaned || push.unknownStatus) reasons.push('push_invalid_state');
    const backgroundFailures = requests.notificationSyncFailures + requests.notificationStartupFailures
      + requests.pushDispatchFailures + requests.pushTransportFailures + requests.smsSendFailures;
    if (backgroundFailures > limit.maxBackgroundFailures) reasons.push('background_failures');
    const status = reasons.length ? 'alert' : requests.completed < limit.minimumRequests ? 'insufficient-data' : 'ok';
    return { status, reasons, exitCode: status === 'ok' ? 0 : status === 'alert' ? 2 : 3,
      generatedAt: data.generatedAt, sampleCount: requests.completed, serverErrors: requests.serverErrors,
      serverErrorRate: requests.serverErrorRate, p95UpperBoundMs: requests.latency.p95UpperBoundMs,
      backgroundFailures, push };
  } catch {
    // Never echo credentials, config paths, response bodies, URLs or network/SQL errors.
    return { status: 'unavailable' as const, reasons: ['probe_failed'], exitCode: 1 };
  }
}
