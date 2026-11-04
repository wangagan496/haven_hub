import { createHash, randomUUID } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, openSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';
import { z } from 'zod';
import { createPrivateDirectory } from './backup.js';
import { acquireProcessLock } from './process-lock.js';
import { readOperationsJson } from './operations-credentials.js';
import { readOperationsCheckConfig, readOperationsToken, runOperationsCheck, type OperationsCheckConfig } from './operations-check.js';
import { monitorObservationSchema, validateCollectorDirectory, type CollectorReceipt } from './operations-monitor-state.js';

export const operationsMonitorConfigSchema = z.object({
  checkConfigFile: z.string().min(1), directory: z.string().min(1),
  intervalSeconds: z.number().int().min(30).max(3600),
  failureSamples: z.number().int().min(1).max(10),
  recoverySamples: z.number().int().min(1).max(10),
  retentionEvents: z.number().int().min(100).max(100000),
}).strict();
export type OperationsMonitorConfig = z.infer<typeof operationsMonitorConfigSchema>;
const observationSchema = monitorObservationSchema;
type Observation = z.infer<typeof observationSchema>;
const incidentSchema = z.object({ id: z.uuid(), openedAt: z.iso.datetime(),
  status: z.enum(['alert', 'unavailable']), reasons: observationSchema.shape.reasons }).strict();
type Incident = z.infer<typeof incidentSchema>;
type EventType = 'sample' | 'incident_opened' | 'incident_updated' | 'incident_recovered' | 'collector_started' | 'collector_stopped';
export type MonitorEvent = { seq: number; at: string; runId: string; event: EventType;
  status: Observation['status'] | null; reasons: Observation['reasons']; incidentId: string | null };

export function readOperationsMonitorConfig(path: string): OperationsMonitorConfig {
  try {
    const config = operationsMonitorConfigSchema.parse(readOperationsJson(path, 8192));
    const root = dirname(resolve(path));
    return { ...config, checkConfigFile: resolve(root, config.checkConfigFile), directory: resolve(root, config.directory) };
  } catch { throw new Error('持续监控配置无效'); }
}

export function operationsMonitorFingerprint(config: OperationsMonitorConfig, check: OperationsCheckConfig) {
  return createHash('sha256').update(JSON.stringify({
    origin: new URL(check.baseUrl).origin, thresholds: check.thresholds, intervalSeconds: config.intervalSeconds,
    failureSamples: config.failureSamples, recoverySamples: config.recoverySamples, timeoutMs: check.timeoutMs,
  })).digest('hex');
}

/** Private, separate SQLite journal: samples and incident transitions commit together. */
export class OperationsJournal {
  private readonly db: DatabaseSync;
  private readonly lock: string;
  private readonly processLock: ReturnType<typeof acquireProcessLock>;
  private readonly runId = randomUUID();
  private incident: Incident | null = null;
  private failures = 0;
  private recoveries = 0;
  private closed = false;
  private receipt: CollectorReceipt | undefined;

  constructor(private readonly config: OperationsMonitorConfig, private readonly fingerprint: string) {
    const directory = resolve(config.directory);
    const created = !existsSync(directory);
    if (created) createPrivateDirectory(directory);
    try { validateCollectorDirectory(directory); }
    catch { throw new Error('监控目录必须是普通专用目录且不能含未知内容'); }
    this.lock = join(directory, 'collector.lock');
    this.processLock = acquireProcessLock(this.lock, this.runId);
    if (this.processLock.recovered) process.stderr.write('{"event":"collector_lock_recovered"}\n');
    let db: DatabaseSync | undefined;
    try {
      const file = join(directory, 'monitor.sqlite');
      if (created) closeSync(openSync(file, 'wx', 0o600));
      else if (!existsSync(file)) throw new Error('已有监控目录缺少数据库');
      db = new DatabaseSync(file);
      db.exec('PRAGMA busy_timeout=5000;');
      if (created) {
        db.exec(`BEGIN IMMEDIATE;
          CREATE TABLE state (id INTEGER PRIMARY KEY CHECK(id=1), fingerprint TEXT NOT NULL, incident TEXT NOT NULL);
          CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, at TEXT NOT NULL, runId TEXT NOT NULL,
            event TEXT NOT NULL, status TEXT, reasons TEXT NOT NULL, incidentId TEXT);
          PRAGMA user_version=1;`);
        db.prepare('INSERT INTO state VALUES (1,?,?)').run(fingerprint, 'null');
        db.exec('COMMIT');
      }
      if (Number(db.prepare('PRAGMA user_version').get()!.user_version) !== 1) throw new Error('监控数据版本不支持');
      const state = db.prepare('SELECT fingerprint,incident FROM state WHERE id=1').get();
      if (!state || state.fingerprint !== fingerprint) throw new Error('监控目标或判定配置已变化，请使用新目录');
      this.incident = incidentSchema.nullable().parse(JSON.parse(String(state.incident)));
      db.exec('PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;');
      this.db = db;
      // Only the lock owner may discard an interrupted publication's reserved temporary file.
      const pending = join(directory, 'collector-status.pending');
      if (existsSync(pending)) unlinkSync(pending);
    } catch (error) {
      db?.close();
      this.releaseLock();
      throw error;
    }
  }

  private releaseLock() {
    this.processLock.release();
  }

  private append(event: EventType, at: string, observation: Observation | null, incidentId: string | null): MonitorEvent {
    const reasons = observation?.reasons ?? [];
    const result = this.db.prepare('INSERT INTO events(at,runId,event,status,reasons,incidentId) VALUES (?,?,?,?,?,?)')
      .run(at, this.runId, event, observation?.status ?? null, JSON.stringify(reasons), incidentId);
    return { seq: Number(result.lastInsertRowid), at, runId: this.runId, event,
      status: observation?.status ?? null, reasons, incidentId };
  }

  private transact(action: () => MonitorEvent[]) {
    if (this.closed) throw new Error('监控日志已关闭');
    this.db.exec('BEGIN IMMEDIATE');
    let events: MonitorEvent[];
    try {
      events = action();
      this.db.prepare(`DELETE FROM events WHERE seq < COALESCE(
        (SELECT seq FROM events ORDER BY seq DESC LIMIT 1 OFFSET ?),0)`).run(this.config.retentionEvents - 1);
      this.db.exec('COMMIT');
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
    // Publish only committed evidence. A failed publication terminates collection, leaving the old receipt stale.
    this.publish(events);
    return events;
  }

  private publish(events: MonitorEvent[]) {
    const event = events[0]!;
    if (event.event !== 'sample' && event.event !== 'collector_started' && event.event !== 'collector_stopped') {
      throw new Error('Invalid receipt event');
    }
    const previous = this.receipt;
    const receipt: CollectorReceipt = {
      version: 1, fingerprint: this.fingerprint, runId: this.runId, pid: process.pid,
      seq: event.seq, startedAt: previous?.startedAt ?? event.at, at: event.at, event: event.event,
      clockRollback: (previous?.clockRollback ?? false) || (!!previous && event.at < previous.at),
      sample: event.event === 'sample' ? { seq: event.seq, at: event.at, status: event.status!, reasons: event.reasons }
        : previous?.sample ?? null,
    };
    const temporary = join(this.config.directory, 'collector-status.pending');
    let created = false;
    try {
      const descriptor = openSync(temporary, 'wx', 0o600);
      created = true;
      try { writeFileSync(descriptor, JSON.stringify(receipt) + '\n'); fsyncSync(descriptor); }
      finally { closeSync(descriptor); }
      renameSync(temporary, join(this.config.directory, 'collector-status.json'));
      created = false;
      this.receipt = receipt;
    } finally { if (created) unlinkSync(temporary); }
  }

  lifecycle(event: 'collector_started' | 'collector_stopped', now = Date.now()) {
    const at = new Date(now).toISOString();
    return this.transact(() => [this.append(event, at, null, this.incident?.id ?? null)]);
  }

  record(raw: unknown, now = Date.now()): MonitorEvent[] {
    const parsed = observationSchema.parse(raw);
    const observation = { ...parsed, reasons: [...new Set(parsed.reasons)].sort() };
    const at = new Date(now).toISOString();
    const bad = observation.status === 'alert' || observation.status === 'unavailable';
    const failures = bad ? Math.min(this.failures + 1, this.config.failureSamples) : 0;
    const recoveries = observation.status === 'ok' ? Math.min(this.recoveries + 1, this.config.recoverySamples) : 0;
    let nextIncident = this.incident;
    let transition: EventType | undefined;
    if (bad && (!this.incident ? failures >= this.config.failureSamples : true)) {
      const status = observation.status as 'alert' | 'unavailable';
      if (!this.incident) {
        nextIncident = { id: randomUUID(), openedAt: at, status, reasons: observation.reasons };
        transition = 'incident_opened';
      } else if (this.incident.status !== status || JSON.stringify(this.incident.reasons) !== JSON.stringify(observation.reasons)) {
        nextIncident = { ...this.incident, status, reasons: observation.reasons };
        transition = 'incident_updated';
      }
    } else if (observation.status === 'ok' && this.incident && recoveries >= this.config.recoverySamples) {
      nextIncident = null;
      transition = 'incident_recovered';
    }
    const events = this.transact(() => {
      const events = [this.append('sample', at, observation, this.incident?.id ?? null)];
      if (transition) events.push(this.append(transition, at, observation, nextIncident?.id ?? this.incident!.id));
      this.db.prepare('UPDATE state SET incident=? WHERE id=1').run(JSON.stringify(nextIncident));
      return events;
    });
    // Only advance in-memory confirmation counters after the transaction commits.
    this.failures = failures; this.recoveries = recoveries; this.incident = nextIncident;
    return events;
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.db.close();
    this.releaseLock();
  }
}

export type MonitorOptions = {
  signal?: AbortSignal; cycles?: number; emit?: (event: MonitorEvent) => void;
  // Tests replace only the wait; checks still use the actual HTTP implementation.
  wait?: (milliseconds: number, signal?: AbortSignal) => Promise<void>;
};

/** A separate serial loop, not an app-server timer or an installed system service. */
export async function runOperationsMonitor(rawConfig: OperationsMonitorConfig, options: MonitorOptions = {}) {
  const config = operationsMonitorConfigSchema.parse(rawConfig);
  if (options.cycles !== undefined && (!Number.isSafeInteger(options.cycles) || options.cycles < 1 || options.cycles > 1000000)) {
    throw new Error('采集次数无效');
  }
  const check = readOperationsCheckConfig(config.checkConfigFile);
  if (check.authentication !== 'operations-key') throw new Error('持续监控必须使用独立只读凭证');
  const fingerprint = operationsMonitorFingerprint(config, check);
  const journal = new OperationsJournal(config, fingerprint);
  const emit = options.emit ?? (event => { process.stdout.write(JSON.stringify(event) + '\n'); });
  const wait = options.wait ?? (async (milliseconds, signal) => { await delay(milliseconds, undefined, { signal }); });
  let samples = 0;
  try {
    journal.lifecycle('collector_started').forEach(emit);
    while (!options.signal?.aborted && samples < (options.cycles ?? Infinity)) {
      let observation: unknown;
      let credential: string | undefined;
      try { credential = readOperationsToken(check.tokenFile); }
      catch { observation = { status: 'unavailable', reasons: ['credential_file_unavailable'] }; }
      if (credential !== undefined) observation = await runOperationsCheck(check, credential, options.signal);
      // Explicit shutdown is not a service outage; discard the cancelled probe.
      if (options.signal?.aborted) break;
      journal.record(observation).forEach(emit);
      samples++;
      if (samples >= (options.cycles ?? Infinity)) break;
      try { await wait(config.intervalSeconds * 1000, options.signal); }
      catch (error) { if (!options.signal?.aborted) throw error; }
    }
    journal.lifecycle('collector_stopped').forEach(emit);
    return { samples };
  } finally { journal.close(); }
}
