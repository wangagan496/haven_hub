import { performance } from 'node:perf_hooks';
import { MAX_ATTEMPTS } from './notifications.js';
import type { Store } from './database.js';

const BUCKET_MS = 10_000;
const BUCKET_COUNT = 60;
const LATENCY_BOUNDS_MS = [50, 100, 250, 500, 1000, 2000, 5000, 10000] as const;
const faultFields = {
  notification_sync_failed: 'notificationSyncFailures',
  notification_startup_sync_failed: 'notificationStartupFailures',
  push_dispatch_failed: 'pushDispatchFailures',
  push_send_failed: 'pushTransportFailures',
  sms_send_failed: 'smsSendFailures',
} as const;
type FaultField = typeof faultFields[keyof typeof faultFields];

function emptyCounts() {
  return { completed: 0, serverErrors: 0, rejected: 0, authRejected: 0, rateLimited: 0, aborted: 0,
    notificationSyncFailures: 0, notificationStartupFailures: 0, pushDispatchFailures: 0,
    pushTransportFailures: 0, smsSendFailures: 0 };
}

/** Fixed-size process-local aggregation. No request/user/path/credential values are retained. */
export class OperationsMetrics {
  private readonly started: number;
  private lastTick: number;
  private activeRequests = 0;
  private readonly buckets: Array<{ tick: number; counts: ReturnType<typeof emptyCounts>; latency: number[] } | undefined>
    = new Array(BUCKET_COUNT);

  constructor(private readonly clock = () => performance.now()) {
    this.started = clock();
    this.lastTick = Math.floor(this.started / BUCKET_MS);
  }

  private tick() {
    // Production uses a monotonic clock, independent of wall-clock corrections.
    this.lastTick = Math.max(this.lastTick, Math.floor(this.clock() / BUCKET_MS));
    return this.lastTick;
  }

  private bucket() {
    const tick = this.tick();
    const index = tick % BUCKET_COUNT;
    let bucket = this.buckets[index];
    if (!bucket || bucket.tick !== tick) {
      bucket = { tick, counts: emptyCounts(), latency: new Array(LATENCY_BOUNDS_MS.length + 1).fill(0) };
      this.buckets[index] = bucket;
    }
    return bucket;
  }

  begin(authRequest: boolean) {
    const started = this.clock();
    this.activeRequests++;
    let done = false;
    return (result?: { status: number; businessError: boolean }) => {
      if (done) return;
      done = true;
      this.activeRequests--;
      const bucket = this.bucket();
      if (!result) { bucket.counts.aborted++; return; }
      const elapsed = Math.max(0, this.clock() - started);
      const index = LATENCY_BOUNDS_MS.findIndex(bound => elapsed <= bound);
      bucket.latency[index < 0 ? LATENCY_BOUNDS_MS.length : index]!++;
      bucket.counts.completed++;
      if (result.status >= 500) bucket.counts.serverErrors++;
      else if (result.status >= 400 || result.businessError) {
        bucket.counts.rejected++;
        if (authRequest) bucket.counts.authRejected++;
      }
      if (result.status === 429) bucket.counts.rateLimited++;
    };
  }

  recordEvent(event: object) {
    const name: unknown = 'event' in event ? event.event : undefined;
    if (typeof name !== 'string' || !Object.hasOwn(faultFields, name)) return;
    const field: FaultField = faultFields[name as keyof typeof faultFields];
    this.bucket().counts[field]++;
  }

  snapshot() {
    const tick = this.tick();
    const counts = emptyCounts();
    const latency = new Array<number>(LATENCY_BOUNDS_MS.length + 1).fill(0);
    for (const bucket of this.buckets) {
      if (!bucket || bucket.tick <= tick - BUCKET_COUNT || bucket.tick > tick) continue;
      for (const key of Object.keys(counts) as Array<keyof typeof counts>) counts[key] += bucket.counts[key];
      bucket.latency.forEach((value, index) => { latency[index]! += value; });
    }
    let cumulative = 0;
    const rank = Math.ceil(counts.completed * 0.95);
    const p95Index = counts.completed ? latency.findIndex(value => { cumulative += value; return cumulative >= rank; }) : -1;
    return {
      scope: 'single-process' as const,
      uptimeMs: Math.max(0, Math.floor(this.clock() - this.started)),
      windowMs: BUCKET_MS * BUCKET_COUNT,
      bucketMs: BUCKET_MS,
      observedMs: Math.max(0, Math.floor(this.clock() - Math.max(this.started, (tick - BUCKET_COUNT + 1) * BUCKET_MS))),
      activeRequests: this.activeRequests,
      ...counts,
      serverErrorRate: counts.completed ? counts.serverErrors / counts.completed : null,
      latency: { p95UpperBoundMs: LATENCY_BOUNDS_MS[p95Index] ?? null,
        buckets: latency.map((count, index) => ({ upperBoundMs: LATENCY_BOUNDS_MS[index] ?? null, count })) },
    };
  }
}

/** Read-only queue inventory, including stranded rows; provider acceptance is not delivery. */
export function pushOperationsSnapshot(store: Store, now: number) {
  const row = store.one(`SELECT COUNT(*) AS activeDeliveries,
    COALESCE(SUM(d.status='queued'),0) AS queued,
    COALESCE(SUM(d.status='failed'),0) AS failed,
    COALESCE(SUM(d.status='sending'),0) AS sending,
    COALESCE(SUM(d.status='accepted'),0) AS accepted,
    COALESCE(SUM(d.status='unconfigured'),0) AS unconfigured,
    COALESCE(SUM(d.status='expired'),0) AS expired,
    COALESCE(SUM(d.status NOT IN ('queued','failed','sending','accepted','unconfigured','expired')),0) AS unknownStatus,
    COALESCE(SUM(d.status IN ('queued','failed') AND d.attempts>=?),0) AS stopped,
    COALESCE(SUM(d.status='sending' AND d.nextAt<=?),0) AS expiredLeases,
    COALESCE(SUM(d.status IN ('queued','failed','sending') AND p.id IS NULL),0) AS orphaned,
    COALESCE(SUM(d.status IN ('queued','failed') AND d.attempts<? AND d.nextAt<=? AND p.id IS NOT NULL),0) AS due,
    MIN(CASE WHEN d.status IN ('queued','failed') AND d.attempts<? AND d.nextAt<=? AND p.id IS NOT NULL THEN d.nextAt END) AS oldestDueAt
    FROM push_deliveries d JOIN notifications n ON n.id=d.notificationId
    LEFT JOIN push_devices p ON p.id=d.deviceId AND p.userId=n.userId WHERE n.active=1`,
    MAX_ATTEMPTS, now, MAX_ATTEMPTS, now, MAX_ATTEMPTS, now)!;
  const count = (key: string) => Number(row[key]);
  return {
    activeDeliveries: count('activeDeliveries'), queued: count('queued'), failed: count('failed'),
    sending: count('sending'), accepted: count('accepted'), unconfigured: count('unconfigured'),
    expired: count('expired'), unknownStatus: count('unknownStatus'), stopped: count('stopped'),
    expiredLeases: count('expiredLeases'), orphaned: count('orphaned'), due: count('due'),
    oldestDueDelayMs: row.oldestDueAt === null ? null : Math.max(0, now - Number(row.oldestDueAt)),
  };
}
