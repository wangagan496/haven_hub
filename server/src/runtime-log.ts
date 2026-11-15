import { createHash, randomUUID } from 'node:crypto';
import { closeSync, constants, existsSync, fstatSync, fsyncSync, lstatSync, openSync, readFileSync, readdirSync, unlinkSync, writeSync } from 'node:fs';
import { isAbsolute, join } from 'node:path';
import { createPrivateDirectory } from './backup.js';
import { acquireProcessLock, ProcessLockOccupiedError } from './process-lock.js';

export interface RuntimeLogSettings { directory: string; maxBytes: number; maxFiles: number }
const failureEvents = new Set(['internal_error', 'notification_startup_sync_failed', 'notification_sync_failed',
  'push_dispatch_failed', 'push_send_failed', 'sms_send_failed', 'web_push_failed', 'huawei_push_rejected',
  'huawei_push_failed', 'repair_settlement_failed', 'repair_list_record_skipped', 'server_config_failed',
  'server_start_failed', 'server_listen_failed', 'server_shutdown_failed', 'server_shutdown_timeout',
  'process_uncaught_exception', 'process_unhandled_rejection']);
const errorTypes = new Set(['Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'URIError', 'AggregateError']);
const methods = new Set(['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS', 'CONNECT', 'TRACE']);
const lifecycleEvents = new Set(['runtime_log_started', 'runtime_log_stopped', 'server_started',
  'server_stopping', 'server_drained', 'server_stopped', 'process_lock_recovered']);
const segmentPattern = /^runtime-(\d{16})\.jsonl$/;
const uuidPattern = /^[a-f\d]{8}-[a-f\d]{4}-4[a-f\d]{3}-[89ab][a-f\d]{3}-[a-f\d]{12}$/i;

/** Project values, never stringify the source object: names and IDs can contain secrets too. */
export function projectRuntimeEvent(input: object, at = Date.now()): Record<string, string | number> {
  const source = input as Record<string, unknown>;
  const event = typeof source.event === 'string' && (failureEvents.has(source.event) || lifecycleEvents.has(source.event))
    ? source.event : source.event === undefined && typeof source.method === 'string' ? 'request_completed' : 'unclassified';
  const result: Record<string, string | number> = { version: 1, at: new Date(at).toISOString(), event };
  if (typeof source.requestId === 'string' && uuidPattern.test(source.requestId)) result.requestId = source.requestId;
  if (event === 'request_completed') {
    result.method = typeof source.method === 'string' && methods.has(source.method) ? source.method : 'OTHER';
    if (Number.isInteger(source.status) && Number(source.status) >= 100 && Number(source.status) <= 599) result.status = Number(source.status);
    if (typeof source.durationMs === 'number' && Number.isFinite(source.durationMs) && source.durationMs >= 0)
      result.durationMs = Math.min(Math.round(source.durationMs), 86_400_000);
  }
  if (failureEvents.has(event)) {
    if (source.type !== undefined) result.type = typeof source.type === 'string' && errorTypes.has(source.type) ? source.type : 'other';
    for (const field of ['statusCode', 'httpStatus'] as const) {
      const value = source[field];
      if (typeof value === 'number' && Number.isInteger(value) && value >= 100 && value <= 599) result[field] = value;
    }
  }
  return result;
}

/** One process per private directory. Synchronous bounded records; no unbounded in-memory queue. */
export class RuntimeLog {
  private fd: number | undefined;
  private path = '';
  private bytes = 0;
  private sequence = 0;
  private closed = false;
  private ownsLock = false;
  private lock = '';
  private readonly lockPath: string;
  private segments: string[] = [];
  failed = false;

  constructor(private readonly settings: RuntimeLogSettings, identity: string,
    private readonly onFailure: () => void = () => { process.stderr.write('{"event":"runtime_log_failed"}\n'); }) {
    this.lockPath = join(settings.directory, 'writer.lock');
    try {
      if (!isAbsolute(settings.directory) || !Number.isInteger(settings.maxBytes) || settings.maxBytes < 1024
        || settings.maxBytes > 16 * 1024 * 1024 || !Number.isInteger(settings.maxFiles) || settings.maxFiles < 2 || settings.maxFiles > 100)
        throw new Error();
      const marker = JSON.stringify({ version: 1, fingerprint: createHash('sha256').update(identity).digest('hex') });
      const isNew = !existsSync(settings.directory);
      if (isNew) createPrivateDirectory(settings.directory);
      const directoryStat = lstatSync(settings.directory);
      if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) throw new Error();
      if (!isNew && this.readSmallFile(join(settings.directory, 'format.json')) !== marker) throw new Error();
      const names = readdirSync(settings.directory);
      if (names.length > 102) throw new Error();
      for (const name of names) {
        if (/^writer\.lock(?:\.reclaim-[a-f0-9]{16})*$/.test(name)) continue;
        if (name !== 'format.json' && !segmentPattern.test(name)) throw new Error();
        const stat = lstatSync(join(settings.directory, name));
        if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) throw new Error();
        if (segmentPattern.test(name) && stat.size > settings.maxBytes) throw new Error();
        if (segmentPattern.test(name)) this.segments.push(name);
      }
      const acquired = acquireProcessLock(this.lockPath);
      this.lock = acquired.content;
      this.ownsLock = true;
      if (isNew) {
        const markerFd = this.openNew(join(settings.directory, 'format.json'));
        try { this.writeAll(markerFd, marker); fsyncSync(markerFd); } finally { closeSync(markerFd); }
      }
      this.segments.sort();
      this.sequence = this.segments.length ? Number(segmentPattern.exec(this.segments.at(-1)!)![1]) : 0;
      if (!Number.isSafeInteger(this.sequence)) throw new Error();
      this.rotate(); // New segment after every restart, never append to a possible crash tail.
      if (acquired.recovered) this.write({ event: 'process_lock_recovered' });
      this.write({ event: 'runtime_log_started' });
      if (this.failed) throw new Error();
    } catch (error) {
      this.close();
      if (error instanceof ProcessLockOccupiedError) throw error;
      throw new Error('运行日志目录不可用，请检查配置、权限和写入锁');
    }
  }

  private openNew(path: string) {
    return openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  }

  private readSmallFile(path: string) {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 512) throw new Error();
    return readFileSync(path, 'utf8');
  }

  private writeAll(fd: number, text: string) {
    const buffer = Buffer.from(text);
    let offset = 0;
    while (offset < buffer.length) {
      const written = writeSync(fd, buffer, offset, buffer.length - offset);
      if (written <= 0) throw new Error();
      offset += written;
    }
  }

  private finishSegment() {
    if (this.fd === undefined) return;
    const fd = this.fd;
    this.fd = undefined;
    try { fsyncSync(fd); } finally { closeSync(fd); }
  }

  private rotate() {
    this.finishSegment();
    if (!Number.isSafeInteger(this.sequence + 1)) throw new Error();
    // Remove only owned segment names, before allocating another file. Keep the latest history.
    while (this.segments.length >= this.settings.maxFiles) {
      const path = join(this.settings.directory, this.segments[0]!);
      const stat = lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) throw new Error();
      unlinkSync(path);
      this.segments.shift();
    }
    const name = `runtime-${String(++this.sequence).padStart(16, '0')}.jsonl`;
    this.path = join(this.settings.directory, name);
    this.fd = this.openNew(this.path);
    this.segments.push(name);
    this.bytes = 0;
  }

  private fail() {
    if (this.failed) return;
    this.failed = true;
    try { this.onFailure(); } catch { /* Readiness remains failed even if stderr is unavailable. */ }
  }

  write(event: object) {
    if (this.closed || this.failed) return;
    try {
      const line = JSON.stringify(projectRuntimeEvent(event)) + '\n';
      const size = Buffer.byteLength(line);
      if (size > 1024) throw new Error();
      if (this.bytes + size > this.settings.maxBytes) this.rotate();
      const stat = fstatSync(this.fd!);
      const visible = lstatSync(this.path);
      if (!stat.isFile() || stat.nlink !== 1 || stat.size !== this.bytes || visible.isSymbolicLink()
        || visible.ino !== stat.ino || visible.dev !== stat.dev) throw new Error();
      this.writeAll(this.fd!, line);
      this.bytes += size;
    } catch { this.fail(); }
  }

  get healthy() { return !this.failed && !this.closed; }

  close() {
    if (this.closed) return;
    if (this.fd !== undefined) this.write({ event: 'runtime_log_stopped' });
    this.closed = true;
    try { this.finishSegment(); } catch { this.fail(); }
    if (this.ownsLock) {
      try {
        if (this.readSmallFile(this.lockPath) !== this.lock) throw new Error();
        unlinkSync(this.lockPath);
        this.ownsLock = false;
      } catch { this.fail(); }
    }
  }
}
