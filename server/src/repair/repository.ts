import type { RecordData, Store } from '../database.js';
import { ApiError } from '../errors.js';
import { ownedUpload } from '../community/resources.js';
import { ensureRounds, requiredSkill } from './model.js';
import { activeRepair, settle } from './policy.js';
import { type Capacity, parseSlot, requireAvailable, requireFreeWorker, scheduleRules } from './schedule.js';
import { holdingEligibility, inRepairPool, readWorkforce, StaffingContext, staffingRejection } from './workforce.js';
import { closeOffer, settleOffer, unstaffedOptions } from './unstaffed.js';

export const ANY_REVISION = -1;
export type Loaded = { owner: string; record: RecordData };
const slotDateWhere = "json_valid(payload) AND json_extract(payload,'$.slot') >= ? AND json_extract(payload,'$.slot') < ?";

export class RepairRepository {
  private readonly badRecordLogs = new Set<string>();

  constructor(private readonly store: Store, private readonly now: () => number,
    private readonly log: (event: object) => void, private readonly publicBaseUrl: string) {}

  private logBadRecordOnce(event: 'repair_settlement_failed', repairId: string, fields: { type: string }) {
    const key = `${event}:${repairId}`;
    if (this.badRecordLogs.has(key)) return;
    this.badRecordLogs.add(key);
    this.log({ event, repairId, ...fields });
  }

  load(id: string): Loaded {
    const row = this.store.one('SELECT userId, payload FROM repairs WHERE id = ?', id);
    if (!row) throw new ApiError(404, 40400, '记录不存在或无权访问');
    const record = JSON.parse(String(row.payload)) as RecordData;
    ensureRounds(record);
    return { owner: String(row.userId), record };
  }

  private refreshStaffingIssue(record: RecordData, context?: StaffingContext): boolean {
    const before = String(record.staffingIssue ?? '');
    record.staffingIssue = this.staffingIssue(record, context);
    if (before === record.staffingIssue) return false;
    record.staffingIncident = Number(record.staffingIncident ?? 0) + 1;
    return true;
  }

  private persistSettlement(loaded: Loaded, context?: StaffingContext) {
    const previousSlot = String(loaded.record.slot ?? '');
    const changedBefore = this.refreshStaffingIssue(loaded.record, context);
    const settled = settle(loaded.record, this.now());
    // 尚未保存的状态变化单独判断；保存成功才使请求快照失效。
    const changedAfter = this.refreshStaffingIssue(loaded.record, settled && context
      ? new StaffingContext(context.workers, [...(context.slots.get(String(loaded.record.slot ?? '')) ?? [])
          .filter(row => row.id !== loaded.record.id), loaded.record]) : context);
    const offerContext = context ?? this.staffingContext();
    const offerChanged = settleOffer(loaded.record, this.now(), offerContext,
      () => this.unstaffedOptions(loaded.record, offerContext));
    if (!settled && !changedBefore && !changedAfter && !offerChanged) return;
    loaded.record.revision = Number(loaded.record.revision ?? 0) + 1;
    this.store.savepoint(() => this.store.save('repairs', loaded.owner, loaded.record, true));
    context?.saved(previousSlot, loaded.record);
  }

  /** 单条结算，自成一个事务。 */
  settleOne(id: string, context?: StaffingContext) {
    this.store.transaction(() => {
      const row = this.store.one('SELECT id FROM repairs WHERE id = ?', id);
      if (row) this.persistSettlement(this.load(id), context);
    });
  }

  /** 逐条结算；坏记录在保存点内回滚并记日志，不阻断其他工单或推送队列。 */
  settleAll(filter: { owner?: string; workerId?: string; slotDate?: string } = {}, context = this.staffingContext(), strict = false) {
    this.store.transaction(() => {
      const rows = filter.owner
        ? this.store.db.prepare('SELECT id, userId, payload FROM repairs WHERE userId = ?').all(filter.owner)
        : filter.workerId
          ? this.store.db.prepare("SELECT id, userId, payload FROM repairs WHERE CASE WHEN json_valid(payload) THEN json_extract(payload, '$.workerId') END = ?").all(filter.workerId)
          : filter.slotDate
            ? this.store.db.prepare(`SELECT id, userId, payload FROM repairs WHERE ${slotDateWhere}`).all(`${filter.slotDate}#`, `${filter.slotDate}$`)
            : this.store.db.prepare('SELECT id, userId, payload FROM repairs').all();
      for (const row of rows) {
        try {
          const record = JSON.parse(String(row.payload)) as RecordData;
          if (filter.workerId && record.workerId !== filter.workerId) continue;
          ensureRounds(record);
          this.persistSettlement({ owner: String(row.userId), record }, context);
          this.badRecordLogs.delete(`repair_settlement_failed:${String(row.id)}`);
        } catch (error) {
          if (strict) throw error;
          this.logBadRecordOnce('repair_settlement_failed', String(row.id), { type: error instanceof Error ? error.name : 'unknown' });
        }
      }
      // 聚合提示独立于 staffingIssue；仅写最早提交单，不参与预约或接单判定。
      const shortages = new Map(context.shortages().map(item => [item.orders[0]!.id, item]));
      // 聚合提示跨住户共享；业务结算过滤不能留下其他住户名下的旧提示。
      for (const row of [...context.slots.values()].flat()) {
        try {
          const loaded = this.load(String(row.id));
          const next = shortages.get(loaded.record.id) ?? null;
          if (JSON.stringify(loaded.record.poolShortage ?? null) === JSON.stringify(next)) continue;
          loaded.record.poolShortage = next;
          loaded.record.poolShortageIncident = Number(loaded.record.poolShortageIncident ?? 0) + 1;
          // 提示不是工单业务变更，不使用户手上的 revision 过期。
          this.store.savepoint(() => this.store.save('repairs', loaded.owner, loaded.record, true));
          context.saved(String(loaded.record.slot ?? ''), loaded.record);
        } catch (error) {
          if (strict) throw error;
          this.logBadRecordOnce('repair_settlement_failed', String(row.id), { type: error instanceof Error ? error.name : 'unknown' });
        }
      }
    });
  }


  /**
   * 先独立提交到期结算，再授权、检查 revision、执行纯动作并保存。
   * 权限失败保留 404/403；旧 revision 返回 409。独立 offer 的关闭原因可在 revision 前给出专用 409。
   */
  mutate(id: string, expected: number, authorize: (loaded: Loaded) => void,
    action: (record: RecordData, now: number) => void, afterSave?: () => void, beforeRevision?: (record: RecordData) => void): Loaded {
    this.settleOne(id);
    return this.store.transaction(() => {
      const loaded = this.load(id);
      authorize(loaded);
      beforeRevision?.(loaded.record);
      const current = Number(loaded.record.revision ?? 0);
      if (expected !== ANY_REVISION && current !== expected) {
        throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      }
      const previousSlot = loaded.record.slot;
      action(loaded.record, this.now());
      if (previousSlot !== loaded.record.slot) closeOffer(loaded.record, this.now(), 'stale');
      this.refreshStaffingIssue(loaded.record);
      loaded.record.revision = current + 1;
      this.store.save('repairs', loaded.owner, loaded.record, true);
      afterSave?.();
      if (!afterSave) this.settleAll();
      // 聚合提示和关联单结算可能已更新当前单，返回保存后的状态。
      loaded.record = this.load(id).record;
      return loaded;
    });
  }

  residentRows(userId: string) {
    return this.store.db.prepare('SELECT id, payload FROM repairs WHERE userId = ? ORDER BY seq DESC').all(userId);
  }

  workerRows(workerId: string) {
    return this.store.db.prepare("SELECT id, payload FROM repairs WHERE CASE WHEN json_valid(payload) THEN json_extract(payload, '$.workerId') END = ? ORDER BY seq DESC").all(workerId);
  }

  allRows() {
    return this.store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq DESC').all();
  }

  user(userId: string) {
    return this.store.one('SELECT nickName, mobile FROM users WHERE id = ?', userId);
  }

  worker(workerId: string) {
    return this.store.one("SELECT id, nickName, mobile FROM users WHERE id = ? AND role = 'worker'", workerId);
  }

  workers() {
    return this.store.db.prepare("SELECT id,nickName,mobile FROM users WHERE role='worker' ORDER BY nickName,id").all();
  }

  poolLocation(record: RecordData) {
    if (record.community !== undefined && record.building !== undefined) return record;
    const row = this.store.one('SELECT rooms.payload FROM rooms JOIN repairs ON repairs.userId=rooms.userId WHERE repairs.id=? AND rooms.id=?', record.id, String(record.houseId ?? ''));
    if (!row) return record;
    const house = JSON.parse(String(row.payload)) as RecordData;
    return { ...record, community: String(house.point ?? ''), building: String(house.building ?? '') };
  }

  workerAvailability() { return readWorkforce(this.store); }
  settleWorkforceAfterClaim() { this.settleAll({}, this.staffingContext(), true); }

  staffingContext() {
    const records: RecordData[] = [];
    for (const row of this.allRows()) {
      try { const record = JSON.parse(String(row.payload)); if (record && typeof record === 'object' && !Array.isArray(record)) records.push(record); } catch { /* 逐条结算记录坏数据。 */ }
    }
    return new StaffingContext(this.workerAvailability(), records);
  }

  unstaffedOptions(record: RecordData, context = this.staffingContext()) {
    return unstaffedOptions(record, this.now(), context, date => this.capacities(date).effective);
  }

  staffingIssue(record: RecordData, context?: StaffingContext) {
    if (!activeRepair(record)) return '';
    if (!record.workerId && !requiredSkill(record)) return '请物业明确所需技能';
    const code = String(record.slot ?? '');
    const ctx = context ?? new StaffingContext(this.workerAvailability(), code
      ? [...this.scheduledRows(code).filter(row => row.id !== record.id), record] : [record]);
    if (record.workerId) return code ? ctx.plan(code).issues.get(record.id) ?? ''
      : holdingEligibility(ctx.workers.find(worker => worker.id === record.workerId), record);
    if (!inRepairPool(record)) return '';
    if (!ctx.eligible(record).length) return '暂无符合条件的师傅可接单，请物业协调人手缺口';
    if (code && (parseSlot(code)?.startsAt ?? Infinity) - this.now() < scheduleRules.leadMs) return '距上门不足 2 小时尚未接单，请物业及时安排';
    return '';
  }

  staffingReason(code: string, record: RecordData, context?: StaffingContext) {
    return context ? context.reason(code, record) : staffingRejection(this.scheduledRows(code), code, this.workerAvailability(), record);
  }

  create(userId: string, houseId: string, attachments: string[], build: (house: RecordData) => RecordData,
    readRows: () => RecordData[]) {
    this.settleAll();
    return this.withList(() => {
      const house = this.store.get('rooms', userId, houseId);
      if (!house) throw new ApiError(404, 40400, '记录不存在或无权访问');
      for (const url of attachments) ownedUpload(this.store, this.publicBaseUrl, userId, url);
      this.store.save('repairs', userId, build(house));
    }, readRows);
  }

  /** 调用方位于创建或 mutate 的 BEGIN IMMEDIATE 事务内，检查和占用不可分割。 */
  checkSlot(code: string, now: number, excludeId?: string, workerId = '') {
    requireAvailable(code, this.capacities(code.slice(0, 10)).effective, this.scheduledRows(code), now, excludeId, workerId);
    if (excludeId) this.checkSkillAvailability(code, { ...this.load(excludeId).record, workerId }, excludeId);
  }

  checkSkillAvailability(code: string, record: RecordData, excludeId?: string) {
    const reason = this.staffingReason(code, { ...record, id: excludeId ?? record.id });
    if (reason) throw new ApiError(409, 40900, reason);
  }

  checkWorker(code: string, workerId: string, excludeId?: string, record?: RecordData) {
    requireFreeWorker(this.scheduledRows(code), code, workerId, excludeId);
    const candidate = record ?? (excludeId ? this.load(excludeId).record : undefined);
    if (candidate) this.checkSkillAvailability(code, { ...candidate, workerId }, excludeId);
  }

  scheduledRows(code: string): RecordData[] {
    // 这里只按索引取候选；有效占用和取消状态的定义只在 schedule.slotOrders 中。
    const rows = this.store.db.prepare("SELECT payload FROM repairs WHERE json_valid(payload) AND json_extract(payload,'$.slot') = ?").all(code);
    return rows.map(row => JSON.parse(String(row.payload)) as RecordData);
  }

  scheduledRowsForDate(date: string): RecordData[] {
    // '#' 与 '$' 之间恰好覆盖当天的所有 slot 前缀，复用 repairs_slot 索引。
    const rows = this.store.db.prepare(`SELECT payload FROM repairs WHERE ${slotDateWhere}`).all(`${date}#`, `${date}$`);
    return rows.map(row => JSON.parse(String(row.payload)) as RecordData);
  }

  capacities(date?: string) {
    const defaults: Capacity = Object.fromEntries(this.store.db.prepare('SELECT hour,capacity FROM repair_capacity_defaults ORDER BY hour').all()
      .map(row => [String(row.hour), Number(row.capacity)]));
    const overrides: Capacity = date ? Object.fromEntries(this.store.db.prepare('SELECT hour,capacity FROM repair_capacity_overrides WHERE date = ? ORDER BY hour').all(date)
      .map(row => [String(row.hour), Number(row.capacity)])) : {};
    const workerCount = Number(this.store.one("SELECT COUNT(*) AS count FROM users WHERE role = 'worker'")!.count);
    // date 已是北京时间的日期；用 UTC 读取这个日历日期，避免宿主机时区参与计算。
    const weekday = date ? new Date(`${date}T00:00:00Z`).getUTCDay() || 7 : null;
    const template = weekday ? this.weekdayCapacities()[weekday]! : {};
    const effective = { ...defaults, ...template, ...overrides };
    const sources = Object.fromEntries(Object.keys(effective).map(hour => [hour,
      Object.hasOwn(overrides, hour) ? 'date' : Object.hasOwn(template, hour) ? 'weekday' : 'default']));
    return { defaults, overrides, effective, workerCount, weekday, sources };
  }

  weekdayCapacities(): Record<number, Capacity> {
    const days: Record<number, Capacity> = Object.fromEntries(Array.from({ length: 7 }, (_, i) => [i + 1, {}]));
    for (const row of this.store.db.prepare('SELECT weekday,hour,capacity FROM repair_capacity_weekdays ORDER BY weekday,hour').all()) {
      days[Number(row.weekday)]![String(row.hour)] = Number(row.capacity);
    }
    return days;
  }

  saveWeekdayCapacities(weekday: number, values: Capacity) {
    return this.store.transaction(() => {
      for (const [hour, capacity] of Object.entries(values)) {
        this.store.run('INSERT INTO repair_capacity_weekdays(weekday,hour,capacity) VALUES (?,?,?) ON CONFLICT(weekday,hour) DO UPDATE SET capacity=excluded.capacity', weekday, hour, capacity);
      }
      return this.weekdayCapacities();
    });
  }

  clearWeekdayCapacities(weekday: number) {
    return this.store.transaction(() => {
      this.store.run('DELETE FROM repair_capacity_weekdays WHERE weekday=?', weekday);
      return this.weekdayCapacities();
    });
  }

  saveCapacities(values: Capacity, date?: string) {
    return this.store.transaction(() => {
      for (const [hour, capacity] of Object.entries(values)) {
        if (date) this.store.run('INSERT INTO repair_capacity_overrides(date,hour,capacity) VALUES (?,?,?) ON CONFLICT(date,hour) DO UPDATE SET capacity=excluded.capacity', date, hour, capacity);
        else this.store.run('UPDATE repair_capacity_defaults SET capacity=? WHERE hour=?', capacity, hour);
      }
      return this.capacities(date);
    });
  }

  clearCapacities(date: string) {
    return this.store.transaction(() => {
      this.store.run('DELETE FROM repair_capacity_overrides WHERE date=?', date);
      return this.capacities(date);
    });
  }

  role(userId: string) { return this.store.one('SELECT role FROM users WHERE id=?', userId)?.role; }

  // 保留创建/旧撤销契约：写入和返回完整列表在同一事务中，读取失败则回滚。
  withList(operation: () => void, readRows: () => RecordData[]) {
    return this.store.transaction(() => {
      operation();
      const rows = readRows();
      return { complete: true, rows, total: rows.length };
    });
  }
}
