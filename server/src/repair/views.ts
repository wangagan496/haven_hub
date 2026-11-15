import type { RecordData } from '../database.js';
import { Status, type Role, currentRound, ensureRounds, events, openPending, repairRoundNumber, repairFees } from './model.js';
import { activeRepair, closed, confirmationAvailability, reworkUsed, todoTags, warrantyEnd } from './policy.js';
import { parseSlot, scheduleDefaults } from './schedule.js';
import { openOffer } from './unstaffed.js';

export function maskMobile(value: unknown) {
  const text = String(value ?? '');
  return /^1\d{10}$/.test(text) ? `${text.slice(0, 3)}****${text.slice(7)}` : text ? '****' : '';
}

export class RepairViews {
  private readonly badRecordLogs = new Set<string>();

  constructor(private readonly now: () => number, private readonly propertyPhone: string,
    private readonly log: (event: object) => void) {}

  /** 接单前使用白名单；不从完整地址推断楼栋，避免历史自由文本泄露门牌。 */
  pool(record: RecordData): RecordData {
    return { id: record.id, revision: record.revision, repairItemId: record.repairItemId,
      repairItemName: record.repairItemName, slot: record.slot ?? '', agreedTime: record.agreedTime ?? '',
      community: record.community ?? '', building: record.building ?? '', description: record.description ?? '' };
  }

  private logBadRecordOnce(event: 'repair_list_record_skipped', repairId: string, fields: { role?: Role; type: string }) {
    const key = `${event}:${repairId}`;
    if (this.badRecordLogs.has(key)) return;
    this.badRecordLogs.add(key);
    this.log({ event, repairId, ...fields });
  }

  view(record: RecordData, role: Role): RecordData {
    const now = this.now();
    const round = currentRound(record);
    const finished = closed(record, now);
    const defaults = scheduleDefaults(record);
    const slot = parseSlot(record.slot ?? defaults.slot);
    const result: RecordData = { ...defaults, ...record,
      availableActions: [confirmationAvailability(record, role)],
      round: repairRoundNumber(record),
      fees: repairFees(record),
      resultReady: Boolean(round.resultSavedAt && round.note && round.cost !== null),
      reworkUsed: reworkUsed(record),
      warrantyEnd: warrantyEnd(record),
      confirmDeadline: record.status === Status.confirming ? round.confirmDeadline : '',
      propertyPhone: this.propertyPhone,
      closed: finished,
      slotWindow: slot ? { start: slot.start, end: slot.end } : null,
      pendingSchedule: openPending(record, 'reschedule')?.firstSchedule ? openPending(record, 'reschedule') : null,
    };
    if (role === 'admin') {
      result.todo = todoTags(record, now);
      result.priorityPending = !record.priority;
      result.preferenceTags = record.asap === true ? ['尽快上门'] : [];
      if (openOffer(record)) result.todo = [...(result.todo as string[]).filter(tag => tag !== '人手待协调'), '等待住户改选时间'];
    }
    // 住户与当前师傅在任务彻底完成（售后期结束）前互相可见电话；物业始终可见。
    if (role !== 'admin' && finished) {
      result.mobile = maskMobile(record.mobile);
      result.workerMobile = maskMobile(record.workerMobile);
    }
    if (role === 'worker') delete result.previousWorkers;
    if (role === 'resident') {
      const returned = (Array.isArray(record.previousWorkers) && record.previousWorkers.length > 0) || record.workforceReturned;
      result.staffingMessage = activeRepair(record) && (record.releasedAt || record.staffingIssue) ? (record.agreedTime
        ? returned ? '原师傅临时有事，正在为您安排新师傅，上门时间不变' : '原定时间暂时排不开师傅，正在为您安排'
        : '正在为您安排师傅') : '';
      delete result.staffingIssue;
      delete result.previousWorkers;
    }
    if (role !== 'admin') {
      delete result.poolShortage;
      delete result.poolShortageIncident;
      result.timeline = events(record).map(event => {
        const visible = { ...event };
        delete visible.previousWorkerId;
        if (role === 'resident' && event.action === 'workforce_returned') {
          visible.label = '正在为您安排师傅';
          visible.detail = record.agreedTime ? '原师傅临时有事，正在为您安排新师傅，上门时间不变' : '正在为您安排师傅';
        }
        return visible;
      });
    }
    return result;
  }

  listViews(rows: Record<string, unknown>[], role: Role, keep?: (record: RecordData) => boolean): RecordData[] {
    return [...this.iterateViews(rows, role, keep)];
  }

  /** Count successfully rendered records, including those outside the requested page.
   * SQL COUNT/LIMIT alone would change the contract when historical payloads are corrupt. */
  pageViews(rows: Iterable<Record<string, unknown>>, role: Role, current: number, pageSize: number,
    keep?: (view: RecordData) => boolean) {
    const page: RecordData[] = [];
    const offset = (current - 1) * pageSize;
    let total = 0;
    for (const view of this.iterateViews(rows, role)) {
      if (keep && !keep(view)) continue;
      if (total >= offset && page.length < pageSize) page.push(view);
      total++;
    }
    return { rows: page, total, pageTotal: Math.ceil(total / pageSize), current };
  }

  private *iterateViews(rows: Iterable<Record<string, unknown>>, role: Role, keep?: (record: RecordData) => boolean): Generator<RecordData> {
    for (const row of rows) {
      try {
        const record = JSON.parse(String(row.payload)) as RecordData;
        if (!record || typeof record !== 'object' || Array.isArray(record)) throw new TypeError();
        if (keep && !keep(record)) continue;
        ensureRounds(record);
        const view = this.view(record, role);
        this.badRecordLogs.delete(`repair_list_record_skipped:${String(row.id)}`);
        yield view;
      } catch (error) {
        this.logBadRecordOnce('repair_list_record_skipped', String(row.id), { role, type: error instanceof Error ? error.name : 'unknown' });
      }
    }
  }

}
