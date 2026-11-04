import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { Store, type RecordData } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';
import { RepairViews } from '../src/repair/views.js';
import { newRound } from '../src/repair/model.js';

// Synthetic materialization benchmark; excludes settlement, HTTP and device load.
const count = 6000;
const pageSize = 20;
const now = () => Date.parse('2026-10-28T00:00:00Z');
const mode = process.argv[2];

if (mode === 'legacy' || mode === 'stream') {
  const store = new Store(':memory:');
  try {
    store.run("INSERT INTO users(id,mobile,nickName) VALUES ('benchmark-owner','13800138000','synthetic')");
    const insert = store.db.prepare('INSERT INTO repairs(id,userId,payload) VALUES (?,?,?)');
    store.transaction(() => {
      for (let index = 0; index < count; index++) {
        insert.run('repair-' + index, 'benchmark-owner', JSON.stringify({ id: 'repair-' + index, status: 0, revision: 1,
          repairItemId: '1004', createdAt: '2026-10-01T00:00:00Z', description: '合成测试'.repeat(400),
          mobile: '13800138000', workerMobile: '13800138001', rounds: [newRound(1, '首次维修', '')], pendings: [],
          timeline: Array.from({ length: 20 }, (_, event) => ({ action: 'note', label: '记录' + event, at: '2026-10-01', by: 'resident', detail: '合成记录'.repeat(20) })) }));
      }
    });
    const repository = new RepairRepository(store, now, () => {}, '');
    const views = new RepairViews(now, '020-88888888', () => {});
    const plan = store.db.prepare('EXPLAIN QUERY PLAN SELECT id, payload FROM repairs WHERE userId = ? ORDER BY seq DESC').all('benchmark-owner');
    assert(global.gc, 'Run with --expose-gc');
    global.gc();
    const before = process.memoryUsage().heapUsed;
    const start = performance.now();
    let retainedViews: RecordData[] | undefined;
    let result: { rows: RecordData[]; total: number; pageTotal: number; current: number };
    if (mode === 'legacy') {
      retainedViews = views.listViews(repository.residentRows('benchmark-owner'), 'resident');
      result = { rows: retainedViews.slice(0, pageSize), total: retainedViews.length, pageTotal: Math.ceil(retainedViews.length / pageSize), current: 1 };
    } else {
      result = views.pageViews(repository.residentRowsIterator('benchmark-owner'), 'resident', 1, pageSize);
    }
    const durationMs = performance.now() - start;
    global.gc();
    const retainedHeapBytes = process.memoryUsage().heapUsed - before;
    const resultHash = createHash('sha256').update(JSON.stringify(result)).digest('hex');
    process.stdout.write(JSON.stringify({ mode, durationMs, retainedHeapBytes, retainedViews: retainedViews?.length ?? result.rows.length,
      total: result.total, resultHash, plan: plan.map(row => row.detail) }));
  } finally { store.close(); }
} else {
  const runs: Record<string, any>[] = [];
  for (let run = 0; run < 3; run++) {
    for (const childMode of ['legacy', 'stream']) {
      const child = spawnSync(process.execPath, ['--expose-gc', '--import', 'tsx', fileURLToPath(import.meta.url), childMode],
        { encoding: 'utf8', timeout: 60000 });
      assert.equal(child.status, 0, child.stdout + child.stderr);
      runs.push(JSON.parse(child.stdout.trim()));
    }
  }
  assert(runs.every(run => run.total === count && run.resultHash === runs[0]!.resultHash), 'Equivalent page output required');
  const median = (values: number[]) => values.sort((left, right) => left - right)[Math.floor(values.length / 2)]!;
  const summary = ['legacy','stream'].map(value => {
    const matching = runs.filter(run => run.mode === value);
    return { mode: value, medianDurationMs: median(matching.map(run => run.durationMs)),
      medianRetainedHeapBytes: median(matching.map(run => run.retainedHeapBytes)), retainedViews: matching[0]!.retainedViews };
  });
  process.stdout.write(JSON.stringify({ node: process.version, dataset: { synthetic: true, count, pageSize, eventsPerRecord: 20 },
    scope: 'resident list materialization only; excludes settlement and HTTP', equivalent: true, summary, runs }, null, 2));
}
