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

/** 检查师傅的技能和请假情况；返回拒绝原因，空字符串表示这两项通过。 */
export function eligibility(worker: WorkerAvailability | undefined, repair: RecordData, timeSlot = '') {
  // 1. 先看这张报修需要什么技能，例如水暖、电气。
  const repairSkill = requiredSkill(repair);
  if (!repairSkill) {
    return '请物业先明确维修技能，再安排师傅或时段';
  }

  // 2. 找不到师傅，或他的技能列表里没有这项技能，就不能安排。
  if (!worker) {
    return '该师傅未登记此类维修技能';
  }
  const hasRequiredSkill = worker.skills.includes(repairSkill);
  if (!hasRequiredSkill) {
    return '该师傅未登记此类维修技能';
  }

  // 3. 已经选了预约时段，就检查他那时是否请假；尚未定时间时只检查技能。
  if (timeSlot !== '') {
    const isOnLeaveAtThisTime = workerOnLeave(worker, timeSlot);
    if (isOnLeaveAtThisTime) {
      return '该师傅此时段正在休假，请物业协调改派或改约';
    }
  }

  // 技能和请假检查通过；同一时段有没有其他工单，由后续检查判断。
  return '';
}

/** 仅从未登记的师傅兼容持有；明确清空技能后，连历史未分类单也不能持有。 */
export function holdingEligibility(worker: WorkerAvailability | undefined, record: RecordData, timeSlot = '') {
  if (!worker || record.workerId !== worker.id) return '该师傅未登记此类维修技能';
  if (timeSlot && workerOnLeave(worker, timeSlot)) return '该师傅此时段正在休假，请物业协调改派或改约';
  const skill = requiredSkill(record);
  if (worker.skillsKnown && (!worker.skills.length || (skill && !worker.skills.includes(skill)))) return '该师傅未登记此类维修技能';
  return '';
}

/** 正常持有单固定；异常安排与未派单共用剩余人手的严格最大匹配。 */
export function staffingPlan(records: readonly RecordData[], timeSlot: string, workers: readonly WorkerAvailability[]) {
  const orders = slotOrders(records, timeSlot);
  const usable = workers.filter(worker => !workerOnLeave(worker, timeSlot));
  const issues = new Map<string, string>();
  const fixed = new Map<string, string>();
  {
    const counts = new Map<string, number>();
    for (const record of orders) if (record.workerId) counts.set(String(record.workerId), (counts.get(String(record.workerId)) ?? 0) + 1);
    for (const record of orders) {
      if (!record.workerId) continue;
      const reason = holdingEligibility(workers.find(worker => worker.id === record.workerId), record, timeSlot)
        || (counts.get(String(record.workerId))! > 1 ? '该师傅此时段已有安排' : '');
      if (reason) issues.set(record.id, reason);
      else fixed.set(record.id, String(record.workerId));
    }
  }
  const reserved = new Set(fixed.values());
  const remaining = orders.filter(record => !fixed.has(record.id));
  const candidates = remaining.map(record => usable.filter(worker => {
    if (reserved.has(worker.id)) return false;
    return !eligibility(worker, record, timeSlot);
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

/**
 * 检查一次预约、派单或改派是否可行，只试算，不保存安排。
 * 返回文字表示拒绝原因；返回空字符串表示这一关通过。
 */
export function staffingRejection(
  currentRepairs: readonly RecordData[],
  timeSlot: string,
  workers: readonly WorkerAvailability[],
  proposedRepair: RecordData,
  currentStaffingPlan = staffingPlan(currentRepairs, timeSlot, workers),
) {
  // 1. 先明确这张单需要什么技能，否则无法判断谁能修。
  const repairSkill = requiredSkill(proposedRepair);
  if (!repairSkill) {
    return '请物业先明确维修技能，再安排师傅或时段';
  }

  // 2. 如果这次指定了师傅，检查他会不会修、是否请假、是否已有其他安排。
  // 尚未指定师傅的预约跳过这一步，下面仍会检查有没有足够的合适人手。
  if (proposedRepair.workerId) {
    const selectedWorker = workers.find(worker => worker.id === proposedRepair.workerId);
    const workerUnavailableReason = eligibility(selectedWorker, proposedRepair, timeSlot);
    if (workerUnavailableReason) {
      return workerUnavailableReason;
    }

    const hasAnotherRepairAtSameTime = workerConflict(
      currentRepairs, timeSlot, String(proposedRepair.workerId), proposedRepair.id,
    );
    if (hasAnotherRepairAtSameTime) {
      return '该师傅此时段已有安排';
    }
  }

  // 3. 假设这次安排成功：用修改后的工单替换旧单，避免把同一张单算两次。
  // 新预约还没有旧单，效果就是把它加入列表。这里没有写入数据库。
  const otherRepairs = currentRepairs.filter(repair => repair.id !== proposedRepair.id);
  const repairAfterChange = { ...proposedRepair, slot: timeSlot };
  const repairsAfterChange = [...otherRepairs, repairAfterChange];
  const staffingPlanAfterChange = staffingPlan(repairsAfterChange, timeSlot, workers);

  // 4. 比较前后有几张单安排不出人；多技能师傅在同一时段也只能算一个人。
  // 例如：原来两单都能安排，甲接水暖后电气单没人接，缺口从 0 变 1，就拒绝。
  const unassignableRepairCountBefore = currentStaffingPlan.shortage;
  const unassignableRepairCountAfter = staffingPlanAfterChange.shortage;
  if (unassignableRepairCountAfter <= unassignableRepairCountBefore) {
    // 没有增加人手缺口，这一关通过；已有缺口由协调流程继续处理。
    return '';
  }

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
      const timeSlot = String(record.slot ?? '');
      const rows = this.slots.get(timeSlot) ?? [];
      rows.push(record); this.slots.set(timeSlot, rows);
    }
  }
  plan(timeSlot: string) {
    if (!this.plans.has(timeSlot)) this.plans.set(timeSlot, staffingPlan(this.slots.get(timeSlot) ?? [], timeSlot, this.workers));
    return this.plans.get(timeSlot)!;
  }
  reason(timeSlot: string, candidate: RecordData) {
    return staffingRejection(this.slots.get(timeSlot) ?? [], timeSlot, this.workers, candidate, this.plan(timeSlot));
  }
  eligible(record: RecordData): string[] {
    if (!inRepairPool(record)) return [];
    const timeSlot = String(record.slot ?? '');
    const key = `${timeSlot}:${requiredSkill(record)}`;
    // 未派单同技能可互换：固定其中任一单给某师傅的缺口相同。
    if (!this.poolCandidates.has(key)) this.poolCandidates.set(key, this.workers.filter(worker =>
      !eligibility(worker, record, timeSlot) && (!timeSlot || !this.reason(timeSlot, { ...record, workerId: worker.id }))).map(worker => worker.id));
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
        const records = [...this.slots].filter(([timeSlot]) => timeSlot.startsWith(date + '#')).flatMap(([, rows]) => rows);
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
    for (const [timeSlot, records] of this.slots) {
      const slot = parseSlot(timeSlot);
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
      result.push({ slot: timeSlot, start: slot.start, end: slot.end, orders: orders.map(workforceOrderSummary),
        orderCount: orders.length, workerCount, matched, shortage,
        message: `${slot.start.slice(5, 10)} ${slot.start.slice(11, 16)} ${types}：${orders.length} 张单有 ${workerCount} 位师傅可接，最多同时安排 ${matched} 张，可能有 ${shortage} 张需要物业安排` });
    }
    return result.sort((a, b) => a.slot.localeCompare(b.slot));
  }
  saved(previousSlot: string, record: RecordData) {
    const next = String(record.slot ?? '');
    for (const timeSlot of new Set([previousSlot, next])) {
      const rows = (this.slots.get(timeSlot) ?? []).filter(row => row.id !== record.id);
      if (timeSlot === next) rows.push(structuredClone(record));
      this.slots.set(timeSlot, rows); this.plans.delete(timeSlot);
      for (const key of this.poolCandidates.keys()) if (key.startsWith(`${timeSlot}:`)) this.poolCandidates.delete(key);
      for (const key of this.alternativeWorkers.keys()) if (key.startsWith(`${timeSlot}:`)) this.alternativeWorkers.delete(key);
      const date = parseSlot(timeSlot)?.date;
      if (date) { this.publicCapacities.delete(date); this.publicSlots.delete(date); }
    }
    // 七天结果（包括“无备选”）依赖任一时段；保存后重新聚合，未受影响的时段仍复用。
    this.skillOptions.clear();
  }
}
