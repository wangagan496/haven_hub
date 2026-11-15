import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { performance } from 'node:perf_hooks';
import { Store } from '../src/database.js';
import { readWorkforce } from '../src/repair/workforce.js';
import type { WorkerAvailability } from '../src/repair/schedule.js';
import type { RepairSkill } from '../src/repair/model.js';

const queries = [
  'SELECT workerId,skill FROM worker_skills',
  'SELECT workerId FROM worker_skill_audit',
  'SELECT workerId,date,hour FROM worker_leaves',
  "SELECT id FROM users WHERE role='worker' AND disabledAt=0",
] as const;
const workerCount = 1000;
const leavesPerWorker = 60;
const mode = process.argv[2];
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)]!;

// Exact pre-change algorithm, used only as a performance and output reference.
function legacy(store: Store): WorkerAvailability[] {
  const skills = store.db.prepare(queries[0]).all();
  const known = new Set([...skills, ...store.db.prepare(queries[1]).all()].map(row => String(row.workerId)));
  const leaves = store.db.prepare(queries[2]).all();
  return store.db.prepare(queries[3]).all().map(row => ({ id: String(row.id), skillsKnown: known.has(String(row.id)),
    skills: skills.filter(item => item.workerId === row.id).map(item => String(item.skill) as RepairSkill),
    leaves: leaves.filter(item => item.workerId === row.id).map(item => ({ date: String(item.date), hour: String(item.hour) })),
  }));
}

if (mode === 'legacy' || mode === 'grouped') {
  assert(global.gc, 'Child process requires --expose-gc');
  const store = new Store(':memory:');
  try {
    store.transaction(() => {
      const user = store.db.prepare("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')");
      const skill = store.db.prepare('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)');
      const audit = store.db.prepare('INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES (?,?,?,?)');
      const leave = store.db.prepare('INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,?,?,?)');
      for (let index = 0; index < workerCount; index++) {
        const id = `worker-${index}`;
        user.run(id, id, id);
        for (const code of ['plumbing', 'electrical', 'doors']) skill.run(id, code);
        audit.run(id, id, id, '2026-10-28');
        for (let day = 0; day < leavesPerWorker; day++) {
          const date = new Date(Date.UTC(2026, 0, 1 + day)).toISOString().slice(0, 10);
          leave.run(id, date, day % 2 ? '10' : '', 'synthetic');
        }
      }
    });
    const load = mode === 'legacy' ? legacy : readWorkforce;
    load(store); // Same single warmup for both implementations.
    const durationsMs: number[] = [];
    let resultHash = '';
    for (let iteration = 0; iteration < 5; iteration++) {
      global.gc();
      const start = performance.now();
      const result = load(store);
      durationsMs.push(performance.now() - start);
      assert.equal(result.length, workerCount);
      assert.equal(result.reduce((sum, worker) => sum + worker.leaves.length, 0), workerCount * leavesPerWorker);
      const hash = createHash('sha256').update(JSON.stringify(result)).digest('hex');
      if (resultHash) assert.equal(hash, resultHash);
      resultHash = hash;
    }
    const plans = queries.map(sql => ({ sql, plan: store.db.prepare('EXPLAIN QUERY PLAN ' + sql).all().map(row => row.detail) }));
    process.stdout.write(JSON.stringify({ mode, medianDurationMs: median(durationsMs), durationsMs, resultHash, plans }));
  } finally { store.close(); }
} else {
  const runs: { mode: string; medianDurationMs: number; durationsMs: number[]; resultHash: string; plans: unknown[] }[] = [];
  for (let run = 0; run < 3; run++) for (const childMode of ['legacy', 'grouped']) {
    const child = spawnSync(process.execPath, ['--expose-gc', '--import', 'tsx', fileURLToPath(import.meta.url), childMode],
      { encoding: 'utf8', timeout: 60000 });
    assert.equal(child.status, 0, child.stdout + child.stderr);
    runs.push(JSON.parse(child.stdout.trim()));
  }
  assert(runs.every(run => run.resultHash === runs[0]!.resultHash));
  const summary = ['legacy', 'grouped'].map(value => ({ mode: value,
    medianDurationMs: median(runs.filter(run => run.mode === value).flatMap(run => run.durationsMs)) }));
  process.stdout.write(JSON.stringify({ node: process.version,
    dataset: { synthetic: true, workerCount, skills: workerCount * 3, audits: workerCount, leaves: workerCount * leavesPerWorker },
    scope: 'readWorkforce only, includes the same four SQLite reads and object assembly; excludes staffing matching, settlement, HTTP and GC pauses',
    equivalent: true, summary, runs }, null, 2));
}
