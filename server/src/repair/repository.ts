import type { RecordData, Store } from '../database.js';
import { ApiError } from '../errors.js';
import { ownedUpload } from '../community/resources.js';
import { ensureRounds } from './model.js';
import { settle } from './policy.js';
import { type Capacity, requireAvailable, requireFreeWorker } from './schedule.js';

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

  private persistSettlement(loaded: Loaded) {
    if (!settle(loaded.record, this.now())) return;
    loaded.record.revision = Number(loaded.record.revision ?? 0) + 1;
    this.store.save('repairs', loaded.owner, loaded.record, true);
  }

  /** 单条结算，自成一个事务。 */
  settleOne(id: string) {
    this.store.transaction(() => {
      const row = this.store.one('SELECT id FROM repairs WHERE id = ?', id);
      if (row) this.persistSettlement(this.load(id));
    });
  }

  /** 逐条结算；坏记录在保存点内回滚并记日志，不阻断其他工单或推送队列。 */
  settleAll(filter: { owner?: string; workerId?: string; slotDate?: string } = {}) {
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
          const processed = this.store.savepoint(() => {
            const record = JSON.parse(String(row.payload)) as RecordData;
            if (filter.workerId && record.workerId !== filter.workerId) return false;
            ensureRounds(record);
            this.persistSettlement({ owner: String(row.userId), record });
            return true;
          });
          if (processed) this.badRecordLogs.delete(`repair_settlement_failed:${String(row.id)}`);
        } catch (error) {
          this.logBadRecordOnce('repair_settlement_failed', String(row.id), { type: error instanceof Error ? error.name : 'unknown' });
        }
      }
    });
  }


  /**
   * 先独立提交到期结算，再授权、检查 revision、执行纯动作并保存。
   * 权限失败保留 404/403；业务检查在动作内，因此已授权的旧 revision 总是返回 409。
   */
  mutate(id: string, expected: number, authorize: (loaded: Loaded) => void,
    action: (record: RecordData, now: number) => void, afterSave?: () => void): Loaded {
    this.settleOne(id);
    return this.store.transaction(() => {
      const loaded = this.load(id);
      authorize(loaded);
      const current = Number(loaded.record.revision ?? 0);
      if (expected !== ANY_REVISION && current !== expected) {
        throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      }
      action(loaded.record, this.now());
      loaded.record.revision = current + 1;
      this.store.save('repairs', loaded.owner, loaded.record, true);
      afterSave?.();
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
  }

  checkWorker(code: string, workerId: string, excludeId?: string) {
    requireFreeWorker(this.scheduledRows(code), code, workerId, excludeId);
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
