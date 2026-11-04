import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { Store, type RecordData } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';
import { StaffingContext } from '../src/repair/workforce.js';
import { RepairViews } from '../src/repair/views.js';
import { compareQueue } from '../src/repair/policy.js';

// Synthetic snapshot construction only; excludes settlement, HTTP and total process RSS.
const count = 6000;
const activeCount = 80;
const now = () => Date.parse('2026-10-28T00:00:00Z');
const mode = process.argv[2];

// Pre-change algorithm: materialize SQL rows and parsed payloads before building the slot index.
function legacySnapshot(repository: RepairRepository) {
  const records: RecordData[] = [];
  for (const row of repository.allRows()) {
    try {
      const record = JSON.parse(String(row.payload));
      if (record && typeof record === 'object' && !Array.isArray(record)) records.push(record);
    } catch { /* Same corrupt-payload behavior as the original snapshot. */ }
  }
  const context = new StaffingContext(repository.workerAvailability(), []);
  for (const record of records) {
    const slot = String(record.slot ?? '');
    const rows = context.slots.get(slot) ?? [];
    rows.push(record); context.slots.set(slot, rows);
  }
  return context;
}

if (mode === 'legacy' || mode === 'compact') {
  const store = new Store(':memory:');
  try {
    store.run("INSERT INTO users(id,mobile,nickName) VALUES ('owner','13800138000','synthetic')");
    for (let index = 0; index < 12; index++) {
      const id = `worker-${index}`;
      store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", id, id, id);
      for (const skill of ['plumbing','electrical','doors']) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', id, skill);
    }
    const insert = store.db.prepare('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)');
    store.transaction(() => {
      for (let index = 0; index < count; index++) {
        insert.run(`repair-${index}`, 'owner', JSON.stringify({ id: `repair-${index}`, status: index < activeCount ? 1 : 0,
          revision: 1, repairItemId: ['1004','1005','1002'][index % 3], requiredSkill: '', workerId: '',
          slot: `2026-10-${28 + index % 3}#10`, priority: 'medium', createdAt: `2026-10-01T00:00:${index % 60}`,
          community: '合成小区', building: '1栋', description: '合成测试'.repeat(400),
          timeline: Array.from({ length: 20 }, (_, event) => ({ action: 'note', label: '记录' + event,
            at: '2026-10-01', by: 'resident', detail: '合成记录'.repeat(20) })), rounds: [], pendings: [] }));
      }
    });
    const repository = new RepairRepository(store, now, () => {}, '');
    const plan = store.db.prepare('EXPLAIN QUERY PLAN SELECT id, payload FROM repairs ORDER BY seq DESC').all();
    assert(global.gc, 'Run with --expose-gc');
    global.gc();
    const before = process.memoryUsage().heapUsed;
    const start = performance.now();
    const context = mode === 'legacy' ? legacySnapshot(repository) : repository.staffingContext();
    const durationMs = performance.now() - start;
    global.gc();
    const retainedHeapBytes = process.memoryUsage().heapUsed - before;
    const views = new RepairViews(now, '', () => {});
    const all = [...context.slots.values()].flat();
    const result = { plans: [...context.slots.keys()].map(slot => [slot, context.plan(slot)]),
      shortages: context.shortages(),
      pool: all.filter(record => context.eligible(record).includes('worker-0')).sort(compareQueue).map(record => views.pool(record)),
      alternatives: context.alternatives('plumbing', now(), () => ({ '10': 50, '11': 50 })) };
    const resultHash = createHash('sha256').update(JSON.stringify(result, (_key, value: unknown) => value instanceof Map ? [...value] : value)).digest('hex');
    process.stdout.write(JSON.stringify({ mode, durationMs, retainedHeapBytes, retainedOrders: all.length,
      resultHash, plan: plan.map(row => row.detail) }));
  } finally { store.close(); }
} else {
  const runs: { mode: string; durationMs: number; retainedHeapBytes: number; retainedOrders: number; resultHash: string; plan: string[] }[] = [];
  for (let run = 0; run < 3; run++) for (const childMode of ['legacy', 'compact']) {
    const child = spawnSync(process.execPath, ['--expose-gc', '--import', 'tsx', fileURLToPath(import.meta.url), childMode],
      { encoding: 'utf8', timeout: 60000 });
    assert.equal(child.status, 0, child.stdout + child.stderr);
    runs.push(JSON.parse(child.stdout.trim()));
  }
  assert(runs.every(run => run.retainedOrders === count && run.resultHash === runs[0]!.resultHash), 'Equivalent staffing and pool output required');
  const median = (values: number[]) => values.sort((a, b) => a - b)[Math.floor(values.length / 2)]!;
  const summary = ['legacy','compact'].map(value => {
    const matching = runs.filter(run => run.mode === value);
    return { mode: value, medianDurationMs: median(matching.map(run => run.durationMs)),
      medianRetainedHeapBytes: median(matching.map(run => run.retainedHeapBytes)), retainedOrders: matching[0]!.retainedOrders };
  });
  process.stdout.write(JSON.stringify({ node: process.version,
    dataset: { synthetic: true, count, activeCount, workers: 12, eventsPerRecord: 20, descriptionCharacters: 1600 },
    scope: 'staffing snapshot construction only; excludes settlement, HTTP and total process RSS',
    equivalent: true, summary, runs }, null, 2));
}
