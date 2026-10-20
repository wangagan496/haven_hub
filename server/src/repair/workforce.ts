import type { RecordData, Store } from '../database.js';
import { requiredSkill, repairItems, Status, type RepairSkill } from './model.js';
import { availableDates, businessDate, parseSlot, scheduleRules, slotAvailability, slotOrders, workerConflict, workerOnLeave, type Capacity, type WorkerAvailability } from './schedule.js';

export function readWorkforce(store: Store): WorkerAvailability[] {
  const skills = store.db.prepare('SELECT workerId,skill FROM worker_skills').all();
  const known = new Set([...skills, ...store.db.prepare('SELECT workerId FROM worker_skill_audit').all()].map(row => String(row.workerId)));
  const leaves = store.db.prepare('SELECT workerId,date,hour FROM worker_leaves').all();
  return store.db.prepare("SELECT id FROM users WHERE role='worker'").all().map(row => ({
    id: String(row.id),
    skillsKnown: known.has(String(row.id)),
    skills: skills.filter(item => item.workerId === row.id).map(item => String(item.skill) as RepairSkill),
    leaves: leaves.filter(item => item.workerId === row.id).map(item => ({ date: String(item.date), hour: String(item.hour) })),
  }));
}

export function eligibility(worker: WorkerAvailability | undefined, record: RecordData, code = '') {
  const skill = requiredSkill(record);
  if (!skill) return '请物业先明确维修技能，再安排师傅或时段';
  if (!worker || !worker.skills.includes(skill)) return '该师傅未登记此类维修技能';
  if (code && workerOnLeave(worker, code)) return '该师傅此时段正在休假，请物业协调改派或改约';
  return '';
}

/** 仅从未登记的师傅兼容持有；明确清空技能后，连历史未分类单也不能持有。 */
export function holdingEligibility(worker: WorkerAvailability | undefined, record: RecordData, code = '') {
  if (!worker || record.workerId !== worker.id) return '该师傅未登记此类维修技能';
  if (code && workerOnLeave(worker, code)) return '该师傅此时段正在休假，请物业协调改派或改约';
  const skill = requiredSkill(record);
  if (worker.skillsKnown && (!worker.skills.length || (skill && !worker.skills.includes(skill)))) return '该师傅未登记此类维修技能';
  return '';
}

/** 正常持有单固定；异常安排与未派单共用剩余人手的严格最大匹配。 */
export function staffingPlan(records: readonly RecordData[], code: string, workers: readonly WorkerAvailability[]) {
  const orders = slotOrders(records, code);
  const usable = workers.filter(worker => !workerOnLeave(worker, code));
  const issues = new Map<string, string>();
  const fixed = new Map<string, string>();
  {
    const counts = new Map<string, number>();
    for (const record of orders) if (record.workerId) counts.set(String(record.workerId), (counts.get(String(record.workerId)) ?? 0) + 1);
    for (const record of orders) {
      if (!record.workerId) continue;
      const reason = holdingEligibility(workers.find(worker => worker.id === record.workerId), record, code)
        || (counts.get(String(record.workerId))! > 1 ? '该师傅此时段已有安排' : '');
      if (reason) issues.set(record.id, reason);
      else fixed.set(record.id, String(record.workerId));
    }
  }
  const reserved = new Set(fixed.values());
  const remaining = orders.filter(record => !fixed.has(record.id));
  const candidates = remaining.map(record => usable.filter(worker => {
    if (reserved.has(worker.id)) return false;
    return !eligibility(worker, record, code);
  }).map(worker => worker.id));
  const matched = maximumMatching(candidates);
  const shortage = remaining.length - matched;
  return { occupied: orders.length, unassigned: orders.filter(order => !order.workerId).length,
    workerCount: usable.filter(worker => worker.skills.length > 0).length, shortage, issues };
}

/** 共用增广路径算法：输入每张单实际允许的师傅，不改变可见性规则。 */
function maximumMatching(candidates: readonly (readonly string[])[]) {
  const assigned = new Map<string, number>();
  const visit = (order: number, seen: Set<string>): boolean => {
    for (const worker of candidates[order]!) {
      if (seen.has(worker)) continue;
      seen.add(worker);
      const previous = assigned.get(worker);
      if (previous === undefined || visit(previous, seen)) { assigned.set(worker, order); return true; }
    }
    return false;
  };
  let matched = 0;
  // 单候选先匹配只是优化；增广保证多技能人手不被重复计数。
  for (const index of candidates.map((_, i) => i).sort((a, b) => candidates[a]!.length - candidates[b]!.length)) {
    if (visit(index, new Set())) matched++;
  }
  return matched;
}

export function workforceOrderSummary(record: RecordData) {
  const slot = parseSlot(record.slot);
  return { id: record.id, repairItemName: record.repairItemName ?? repairItems.find(item => item.id === record.repairItemId)?.name ?? '维修',
    slot: record.slot ?? '', agreedTime: record.agreedTime ?? '', start: slot?.start ?? '', end: slot?.end ?? '' };
}

export type PoolShortage = { slot: string; start: string; end: string; orders: ReturnType<typeof workforceOrderSummary>[];
  orderCount: number; workerCount: number; matched: number; shortage: number; message: string };

export function staffingRejection(records: readonly RecordData[], code: string, workers: readonly WorkerAvailability[], candidate: RecordData,
  before = staffingPlan(records, code, workers)) {
  if (!requiredSkill(candidate)) return '请物业先明确维修技能，再安排师傅或时段';
  if (candidate.workerId) {
    const reason = eligibility(workers.find(worker => worker.id === candidate.workerId), candidate, code);
    if (reason) return reason;
    if (workerConflict(records, code, String(candidate.workerId), candidate.id)) return '该师傅此时段已有安排';
  }
  const others = records.filter(record => record.id !== candidate.id);
  const next = staffingPlan([...others, { ...candidate, slot: code }], code, workers);
  if (next.shortage <= before.shortage) return '';
  return '该时段人手或技能不足（含未派单预约），请物业协调改派或其他时段';
}

export function inRepairPool(record: RecordData) {
  return record.status === Status.pending && !record.workerId && record.priority !== 'urgent'
    && (!record.urgentRequest || Boolean(record.priority)) && Boolean(requiredSkill(record));
}

/** 请求级快照。索引包含全部工单，筛选条件只影响结算对象。 */
export class StaffingContext {
  readonly slots = new Map<string, RecordData[]>();
  private readonly plans = new Map<string, ReturnType<typeof staffingPlan>>();
  private readonly poolCandidates = new Map<string, string[]>();
  private readonly publicCapacities = new Map<string, Capacity>();
  private readonly publicSlots = new Map<string, ReturnType<typeof slotAvailability>>();
  private readonly alternativeWorkers = new Map<string, number>();
  private readonly skillOptions = new Map<RepairSkill | '', (ReturnType<typeof slotAvailability>[number] & { eligibleWorkerCount: number })[]>();
  private optionsClock = '';
  constructor(readonly workers: readonly WorkerAvailability[], records: readonly RecordData[]) {
    for (const record of records) {
      const code = String(record.slot ?? '');
      const rows = this.slots.get(code) ?? [];
      rows.push(record); this.slots.set(code, rows);
    }
  }
  plan(code: string) {
    if (!this.plans.has(code)) this.plans.set(code, staffingPlan(this.slots.get(code) ?? [], code, this.workers));
    return this.plans.get(code)!;
  }
  reason(code: string, candidate: RecordData) {
    return staffingRejection(this.slots.get(code) ?? [], code, this.workers, candidate, this.plan(code));
  }
  eligible(record: RecordData): string[] {
    if (!inRepairPool(record)) return [];
    const code = String(record.slot ?? '');
    const key = `${code}:${requiredSkill(record)}`;
    // 未派单同技能可互换：固定其中任一单给某师傅的缺口相同。
    if (!this.poolCandidates.has(key)) this.poolCandidates.set(key, this.workers.filter(worker =>
      !eligibility(worker, record, code) && (!code || !this.reason(code, { ...record, workerId: worker.id }))).map(worker => worker.id));
    return this.poolCandidates.get(key)!;
  }
  /** 包含原时段的技能候选集；入口最后排除原时段。空数组也缓存。 */
  alternatives(skill: RepairSkill | '', now: number, capacities: (date: string) => Capacity) {
    // 可预约边界是整点开始时间减 leadMs；ceil 保留恰好等于边界时仍可选的规则。
    const clock = `${businessDate(now)}:${Math.ceil((now + scheduleRules.leadMs) / 3_600_000)}`;
    if (clock !== this.optionsClock) {
      this.publicSlots.clear(); this.skillOptions.clear(); this.optionsClock = clock;
    }
    const cached = this.skillOptions.get(skill);
    if (cached) return cached;
    const options = availableDates(now).flatMap(date => {
      if (!this.publicCapacities.has(date)) this.publicCapacities.set(date, capacities(date));
      if (!this.publicSlots.has(date)) {
        const records = [...this.slots].filter(([code]) => code.startsWith(date + '#')).flatMap(([, rows]) => rows);
        this.publicSlots.set(date, slotAvailability(date, this.publicCapacities.get(date)!, records, now));
      }
      return this.publicSlots.get(date)!.filter(slot => slot.selectable).flatMap(slot => {
        const key = `${slot.slot}:${skill}`;
        if (!this.alternativeWorkers.has(key)) {
          const records = this.slots.get(slot.slot) ?? [];
          // 原时段不返回；其余时段中没有本单，候选只取决于技能。
          // 用不与任何现存单冲突的临时 id，使整组技能结果也能包含原时段，供其他单复用。
          let id = '__unstaffed_candidate__';
          while (records.some(record => record.id === id)) id += '_';
          const candidate = { id, status: Status.pending, requiredSkill: skill, slot: slot.slot, workerId: '' };
          const count = this.reason(slot.slot, candidate) ? 0
            : new StaffingContext(this.workers, [...records, candidate]).eligible(candidate).length;
          this.alternativeWorkers.set(key, count);
        }
        const eligibleWorkerCount = this.alternativeWorkers.get(key)!;
        return eligibleWorkerCount ? [{ ...slot, eligibleWorkerCount }] : [];
      });
    });
    this.skillOptions.set(skill, options);
    return options;
  }
  shortages(): PoolShortage[] {
    const result: PoolShortage[] = [];
    for (const [code, records] of this.slots) {
      const slot = parseSlot(code);
      if (!slot) continue;
      const orders = records.filter(record => inRepairPool(record) && this.eligible(record).length > 0)
        .sort((a, b) => String(a.createdAt ?? '').localeCompare(String(b.createdAt ?? '')) || a.id.localeCompare(b.id));
      const candidates = orders.map(record => this.eligible(record));
      const matched = maximumMatching(candidates);
      const shortage = orders.length - matched;
      if (!shortage) continue;
      const workerCount = new Set(candidates.flat()).size;
      const names: Record<RepairSkill, string> = { plumbing: '水暖', electrical: '电气', doors: '门窗五金' };
      const types = [...new Set(orders.flatMap(record => {
        const skill = requiredSkill(record);
        return skill ? [names[skill]] : [];
      }))].join('、');
      result.push({ slot: code, start: slot.start, end: slot.end, orders: orders.map(workforceOrderSummary),
        orderCount: orders.length, workerCount, matched, shortage,
        message: `${slot.start.slice(5, 10)} ${slot.start.slice(11, 16)} ${types}：${orders.length} 张单有 ${workerCount} 位师傅可接，最多同时安排 ${matched} 张，可能有 ${shortage} 张需要物业安排` });
    }
    return result.sort((a, b) => a.slot.localeCompare(b.slot));
  }
  saved(previousSlot: string, record: RecordData) {
    const next = String(record.slot ?? '');
    for (const code of new Set([previousSlot, next])) {
      const rows = (this.slots.get(code) ?? []).filter(row => row.id !== record.id);
      if (code === next) rows.push(structuredClone(record));
      this.slots.set(code, rows); this.plans.delete(code);
      for (const key of this.poolCandidates.keys()) if (key.startsWith(`${code}:`)) this.poolCandidates.delete(key);
      for (const key of this.alternativeWorkers.keys()) if (key.startsWith(`${code}:`)) this.alternativeWorkers.delete(key);
      const date = parseSlot(code)?.date;
      if (date) { this.publicCapacities.delete(date); this.publicSlots.delete(date); }
    }
    // 七天结果（包括“无备选”）依赖任一时段；保存后重新聚合，未受影响的时段仍复用。
    this.skillOptions.clear();
  }
}
