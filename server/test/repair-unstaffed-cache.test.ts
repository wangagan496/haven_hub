import test from 'node:test';
import assert from 'node:assert/strict';
import { Store, type RecordData } from '../src/database.js';
import { RepairRepository } from '../src/repair/repository.js';
import { availableDates, scheduleRules, slotAvailability, type Capacity, type WorkerAvailability } from '../src/repair/schedule.js';
import { StaffingContext } from '../src/repair/workforce.js';
import { unstaffedOptions } from '../src/repair/unstaffed.js';
import { START, SLOT, NEXT, H } from './repair-fixture.js';

// 修复前算法的独立对照：每单、每日期、每候选重新计算，不调用 alternatives。
function recomputedOptions(record: RecordData, now: number, context: StaffingContext, capacities: (date: string) => Capacity) {
  return availableDates(now).flatMap(date => slotAvailability(date, capacities(date),
    [...context.slots.values()].flat().filter(row => String(row.slot ?? '').startsWith(date + '#')), now, record.id)
    .filter(slot => slot.selectable && slot.slot !== record.slot)
    .flatMap(slot => {
      const candidate = { ...record, slot: slot.slot, workerId: '' };
      if (context.reason(slot.slot, candidate)) return [];
      const target = new StaffingContext(context.workers,
        [...(context.slots.get(slot.slot) ?? []).filter(row => row.id !== record.id), candidate]);
      const eligibleWorkerCount = target.eligible(candidate).length;
      return eligibleWorkerCount ? [{ ...slot, eligibleWorkerCount }] : [];
    }));
}

function random(seed: number) {
  let state = seed >>> 0;
  return () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 0x100000000; };
}
function repository(store: Store) { return new RepairRepository(store, () => START, () => {}, ''); }
function owner(store: Store) { store.run("INSERT INTO users(id,mobile,nickName) VALUES ('owner','18800000000','owner')"); }
function worker(store: Store, id: string, skills: string[], leaves: { date: string; hour: string }[] = []) {
  store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", id, `1990000000${id.slice(-1)}`, id);
  for (const skill of skills) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', id, skill);
  for (const leave of leaves) store.run('INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,?,?,?)', id, leave.date, leave.hour, 'test');
}
function snapshot(repo: RepairRepository) {
  return repo.allRows().map(row => {
    const record = JSON.parse(String(row.payload)) as RecordData;
    const offer = record.rescheduleOffer as Record<string, unknown> | undefined;
    return { id: record.id, rescheduleOffer: offer ? { ...offer, id: '<offer-id>' } : offer,
      unstaffedFallback: record.unstaffedFallback, staffingIssue: record.staffingIssue,
      staffingIncident: record.staffingIncident, revision: record.revision };
  }).sort((a, b) => a.id.localeCompare(b.id));
}

test('unstaffed cache: seeded settlements equal full recomputation for every order and lifecycle field', () => {
  for (const seed of [7, 47, 649, 3000]) for (const mode of ['mixed', 'no-workers', 'no-capacity', 'all-on-leave']) {
    const rng = random(seed);
    const dates = availableDates(START);
    const codes = dates.flatMap(date => scheduleRules.hours.map(hour => `${date}#${String(hour).padStart(2, '0')}`));
    const skills = ['plumbing', 'electrical', 'doors'];
    const workers = Array.from({ length: 5 }, (_, i) => ({ id: `w${i}`,
      skills: mode === 'no-workers' ? [] : skills.filter((_, s) => s === i % 3 || rng() < 0.3),
      leaves: mode === 'all-on-leave' ? dates.map(date => ({ date, hour: '' }))
        : dates.flatMap((date, d) => (d === i % 7 || rng() < 0.2) ? [{ date, hour: d % 2 ? '' : '10' }] : []),
    }));
    const records: RecordData[] = Array.from({ length: 90 }, (_, i) => {
      const slot = codes[Math.floor(rng() * codes.length)]!;
      const row: RecordData = { id: `r${i}`, status: i % 5 === 0 ? 2 : 1,
        workerId: i % 5 === 0 ? `w${Math.floor(rng() * workers.length)}` : '',
        repairItemId: ['1004', '1005', '1002'][i % 3], slot, revision: 1 + i % 4, staffingIncident: i % 3,
        createdAt: new Date(START - i * 1000).toISOString() };
      if (i % 11 === 0) row.pendings = [{ id: `revoke${i}`, kind: 'revoke', deadline: new Date(START - 1000).toISOString() }];
      if (i % 7 === 0) row.rescheduleOffer = { id: `existing${i}`, offeredAt: new Date(START - H).toISOString(),
        deadline: new Date(START + (i % 2 ? H : -H)).toISOString(), slot, incident: i % 3,
        ...(i % 14 === 0 ? { resolvedAt: new Date(START - H / 2).toISOString(), resolution: 'stale' } : {}) };
      if (i % 17 === 0) row.unstaffedFallback = 'insufficient_response';
      return row;
    });
    // 固定边界样本：无师傅技能、原时段临近、未知技能、急单、无时间和首次定时到期。
    records.push({ id: 'unknown', repairItemId: '1003', status: 1, slot: SLOT, revision: 1 },
      { id: 'short-deadline', repairItemId: '1005', status: 1, slot: '2026-10-17#10', revision: 1 },
      { id: 'urgent', repairItemId: '1004', status: 1, priority: 'urgent', slot: SLOT, revision: 1 },
      { id: 'unscheduled', repairItemId: '1004', status: 1, slot: '', revision: 1 },
      { id: 'first-schedule', repairItemId: '1004', status: 1, slot: '', revision: 1,
        pendings: [{ id: 'proposal', kind: 'reschedule', firstSchedule: true, proposedSlot: NEXT, deadline: new Date(START - 1000).toISOString() }] });
    const stores = [new Store(':memory:'), new Store(':memory:')];
    try {
      const repos = stores.map(store => {
        owner(store); for (const w of workers) worker(store, w.id, w.skills, w.leaves);
        store.run('UPDATE repair_capacity_defaults SET capacity=?', mode === 'no-capacity' ? 0 : 4);
        for (const row of records) store.save('repairs', 'owner', structuredClone(row));
        return repository(store);
      });
      const cached = repos[0]!; const uncached = repos[1]!;
      // 只关闭此次新增的备选缓存；已有 plan/eligible 结算机制两边保持修复前行为。
      uncached.unstaffedOptions = (record, context = uncached.staffingContext()) =>
        recomputedOptions(record, START, context, date => uncached.capacities(date).effective);
      for (let pass = 0; pass < 2; pass++) {
        cached.settleAll({}, cached.staffingContext(), true);
        uncached.settleAll({}, uncached.staffingContext(), true);
        assert.deepEqual(snapshot(cached), snapshot(uncached), `seed=${seed} mode=${mode} pass=${pass}`);
      }
    } finally { for (const store of stores) store.close(); }
  }
});

test('unstaffed cache: settlement save invalidates empty alternatives before the next order', () => {
  const store = new Store(':memory:');
  try {
    owner(store); worker(store, 'w0', ['plumbing']);
    store.run('UPDATE repair_capacity_defaults SET capacity=0');
    store.run('INSERT INTO repair_capacity_overrides(date,hour,capacity) VALUES (?,?,1)', NEXT.slice(0, 10), '11');
    const base = { status: 1, repairItemId: '1004', slot: SLOT, revision: 1 };
    store.save('repairs', 'owner', { ...base, id: 'before-release' });
    store.save('repairs', 'owner', { ...base, id: 'release', status: 2, workerId: 'w0', slot: NEXT,
      pendings: [{ id: 'cancel', kind: 'revoke', deadline: new Date(START - 1000).toISOString() }] });
    store.save('repairs', 'owner', { ...base, id: 'after-release' });
    store.save('repairs', 'owner', { ...base, id: 'source-busy', status: 2, workerId: 'w0' });
    const repo = repository(store); const seen = new Map<string, string[]>();
    const options = repo.unstaffedOptions.bind(repo);
    repo.unstaffedOptions = (record, context) => {
      const actual = options(record, context);
      assert.deepEqual(actual, recomputedOptions(record, START, repo.staffingContext(), date => repo.capacities(date).effective));
      seen.set(record.id, actual.map(slot => slot.slot)); return actual;
    };
    repo.settleAll({}, repo.staffingContext(), true);
    assert.deepEqual(seen.get('before-release'), []);
    assert.deepEqual(seen.get('after-release'), [NEXT]);
    assert.equal(repo.load('before-release').record.rescheduleOffer, undefined);
    assert(repo.load('after-release').record.rescheduleOffer);
    assert.equal(repo.load('release').record.slot, '');
  } finally { store.close(); }
});

test('unstaffed cache: saved move invalidates both dates and slots against fresh database reads', () => {
  const store = new Store(':memory:');
  try {
    owner(store); worker(store, 'w0', ['plumbing']);
    store.run('UPDATE repair_capacity_defaults SET capacity=1');
    const oldSlot = NEXT; const newSlot = '2026-10-19#11';
    const candidate = { id: 'candidate', status: 1, repairItemId: '1004', slot: SLOT };
    const held = { id: 'moving', status: 2, workerId: 'w0', repairItemId: '1004', slot: oldSlot };
    store.save('repairs', 'owner', candidate); store.save('repairs', 'owner', held);
    const repo = repository(store); const context = repo.staffingContext();
    const before = repo.unstaffedOptions(candidate, context);
    assert(!before.some(slot => slot.slot === oldSlot)); assert(before.some(slot => slot.slot === newSlot));
    const moved = { ...held, slot: newSlot }; store.save('repairs', 'owner', moved, true); context.saved(oldSlot, moved);
    const after = repo.unstaffedOptions(candidate, context);
    assert.deepEqual(after, recomputedOptions(candidate, START, repo.staffingContext(), date => repo.capacities(date).effective));
    assert(after.some(slot => slot.slot === oldSlot)); assert(!after.some(slot => slot.slot === newSlot));
  } finally { store.close(); }
});

test('unstaffed cache: saved worker move invalidates alternative workers despite spare public capacity', () => {
  const store = new Store(':memory:');
  try {
    owner(store); worker(store, 'w0', ['plumbing']);
    store.run('UPDATE repair_capacity_defaults SET capacity=5');
    const previousSlot = '2026-10-19#11';
    const candidate = { id: 'candidate', status: 1, repairItemId: '1004', workerId: '', slot: SLOT };
    const held = { id: 'moving', status: 2, repairItemId: '1004', workerId: 'w0', slot: previousSlot };
    store.save('repairs', 'owner', candidate); store.save('repairs', 'owner', held);
    const repo = repository(store); const context = repo.staffingContext();
    assert(repo.unstaffedOptions(candidate, context).some(slot => slot.slot === NEXT));
    const moved = { ...held, slot: NEXT };
    store.save('repairs', 'owner', moved, true);
    context.saved(previousSlot, moved);
    const after = repo.unstaffedOptions(candidate, context);
    assert.deepEqual(after, repo.unstaffedOptions(repo.load(candidate.id).record, repo.staffingContext()));
    assert(!after.some(slot => slot.slot === NEXT));
  } finally { store.close(); }
});

test('unstaffed cache: date and skill results including empty seven-day results are shared', () => {
  const workers: WorkerAvailability[] = [{ id: 'w0', skills: ['plumbing'], skillsKnown: true, leaves: [] }];
  const records = Array.from({ length: 20 }, (_, i) => ({ id: `r${i}`, status: 1, repairItemId: '1005', slot: i % 2 ? SLOT : NEXT }));
  const context = new StaffingContext(workers, records);
  const calls = new Map<string, number>(); let reasons = 0;
  const reason = context.reason.bind(context); context.reason = (...args) => { reasons++; return reason(...args); };
  const capacity = (date: string) => { calls.set(date, (calls.get(date) ?? 0) + 1); return Object.fromEntries(scheduleRules.hours.map(h => [String(h).padStart(2, '0'), 50])); };
  assert.deepEqual(unstaffedOptions(records[0]!, START, context, capacity), []); const firstReasons = reasons;
  assert(firstReasons > 0);
  for (const row of records.slice(1)) assert.deepEqual(unstaffedOptions(row, START + 1, context, capacity), []);
  assert.equal(reasons, firstReasons);
  assert.deepEqual([...calls.values()], Array(7).fill(1));
  const plumbing = { ...records[0]!, repairItemId: '1004' };
  assert.deepEqual(unstaffedOptions(plumbing, START, context, capacity),
    recomputedOptions(plumbing, START, new StaffingContext(workers, records), () => capacity('reference')));
});

test('unstaffed cache: time boundary refresh preserves exact two-hour eligibility', () => {
  const workers: WorkerAvailability[] = [{ id: 'w0', skills: ['plumbing'], skillsKnown: true, leaves: [] }];
  const row = { id: 'r', status: 1, repairItemId: '1004', slot: SLOT };
  const context = new StaffingContext(workers, [row]);
  const capacity = () => Object.fromEntries(scheduleRules.hours.map(h => [String(h).padStart(2, '0'), 50]));
  assert(unstaffedOptions(row, START, context, capacity).some(slot => slot.slot === '2026-10-17#10'));
  assert(!unstaffedOptions(row, START + 1, context, capacity).some(slot => slot.slot === '2026-10-17#10'));
  assert.deepEqual(unstaffedOptions(row, START + 24 * H, context, capacity),
    recomputedOptions(row, START + 24 * H, new StaffingContext(workers, [row]), capacity));
});
