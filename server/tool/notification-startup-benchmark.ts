import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { Store } from '../src/database.js';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { Notifications } from '../src/notifications.js';
import type { PushTransport } from '../src/push-transport.js';

// Executes the real startup loop. Legacy mode substitutes eager all() only for its repair reader.
// Memory is sampled after GC at the first sync, not the peak of the whole startup process.
const count = 6000;
const now = () => Date.parse('2026-10-28T00:00:00Z');
const mode = process.argv[2];
const query = 'SELECT userId,payload FROM repairs';

if (mode === 'legacy' || mode === 'stream') {
  assert(global.gc, 'Run with --expose-gc');
  const folder = mkdtempSync(join(tmpdir(), 'haven-startup-benchmark-'));
  const path = join(folder, 'synthetic.sqlite');
  const prepare = DatabaseSync.prototype.prepare;
  const sync = Notifications.prototype.sync;
  let app: ReturnType<typeof createApp> | undefined;
  let rebuilding = false;
  let before = 0;
  let sampledHeapBytes = 0;
  let synced = 0;
  let durationMs = 0;
  let samplePauseMs = 0;
  try {
    const seed = new Store(path);
    try {
      seed.run("INSERT INTO users(id,mobile,nickName) VALUES ('owner','13800138000','synthetic')");
      const insert = seed.db.prepare('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)');
      seed.transaction(() => {
        for (let i = 0; i < count; i++) insert.run(`repair-${i}`, 'owner', JSON.stringify({ id: `repair-${i}`,
          status: 6, revision: 1, rounds: [{ number: 1 }], pendings: [], description: '合成数据'.repeat(400),
          timeline: Array.from({ length: 20 }, (_, event) => ({ action: 'note', label: '记录' + event,
            at: '2026-10-01', by: 'resident', detail: '合成记录'.repeat(20) })) }));
      });
    } finally { seed.close(); }
    DatabaseSync.prototype.prepare = function (sql) {
      const statement = prepare.call(this, sql);
      if (sql === query) {
        const iterate = statement.iterate.bind(statement);
        statement.iterate = function* () {
          global.gc!();
          before = process.memoryUsage().heapUsed;
          const start = performance.now();
          rebuilding = true;
          try {
            const rows = mode === 'legacy' ? statement.all().values() : iterate();
            yield* rows;
          } finally { durationMs = performance.now() - start - samplePauseMs; rebuilding = false; }
          return undefined;
        };
      }
      return statement;
    };
    Notifications.prototype.sync = function (owner, record) {
      if (rebuilding) {
        if (synced === 0) {
          const start = performance.now();
          global.gc!();
          sampledHeapBytes = process.memoryUsage().heapUsed - before;
          samplePauseMs = performance.now() - start;
        }
        synced++;
      }
      return sync.call(this, owner, record);
    };
    const transport: PushTransport = { publicConfig: () => ({ webPublicKey: '', harmonyConfigured: false }),
      send: async () => { throw new Error('Benchmark must not send push'); } };
    app = createApp(readConfig({ DATABASE_PATH: path }), { now, pushTimer: false, pushTransport: transport,
      log: () => { throw new Error('Unexpected benchmark notification failure'); } });
    const notes = app.store.db.prepare('SELECT repairId,userId,taskKey,role,title,body,active,createdAt FROM notifications ORDER BY repairId').all();
    assert.equal(notes.length, count);
    assert.equal(synced, count);
    const resultHash = createHash('sha256').update(JSON.stringify(notes)).digest('hex');
    const plan = app.store.db.prepare('EXPLAIN QUERY PLAN ' + query).all().map(row => row.detail);
    process.stdout.write(JSON.stringify({ mode, durationMs, sampledHeapBytes, synced, resultHash, plan }));
  } finally {
    DatabaseSync.prototype.prepare = prepare;
    Notifications.prototype.sync = sync;
    app?.store.close();
    rmSync(folder, { recursive: true, force: true });
  }
} else {
  const runs: { mode: string; durationMs: number; sampledHeapBytes: number; synced: number; resultHash: string; plan: string[] }[] = [];
  for (let run = 0; run < 3; run++) for (const childMode of ['legacy', 'stream']) {
    const child = spawnSync(process.execPath, ['--expose-gc', '--import', 'tsx', fileURLToPath(import.meta.url), childMode],
      { encoding: 'utf8', timeout: 60000 });
    assert.equal(child.status, 0, child.stdout + child.stderr);
    runs.push(JSON.parse(child.stdout.trim()));
  }
  assert(runs.every(run => run.synced === count && run.resultHash === runs[0]!.resultHash));
  const median = (values: number[]) => values.sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
  const summary = ['legacy', 'stream'].map(value => {
    const matching = runs.filter(run => run.mode === value);
    return { mode: value, medianDurationMs: median(matching.map(run => run.durationMs)),
      medianSampledHeapBytes: median(matching.map(run => run.sampledHeapBytes)) };
  });
  process.stdout.write(JSON.stringify({ node: process.version,
    dataset: { synthetic: true, count, eventsPerRecord: 20, descriptionCharacters: 1600, devices: 0 },
    scope: 'real startup notification rebuild, excluding settlement and sample GC pause; heap delta at first sync after GC, not full startup peak or RSS',
    equivalent: true, summary, runs }, null, 2));
}
