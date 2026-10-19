import type { RecordData } from '../database.js';
import { Status, type Role, currentRound, ensureRounds, events, openPending } from './model.js';
import { closed, reworkUsed, todoTags, warrantyEnd } from './policy.js';
import { parseSlot, scheduleDefaults } from './schedule.js';

export function maskMobile(value: unknown) {
  const text = String(value ?? '');
  return /^1\d{10}$/.test(text) ? `${text.slice(0, 3)}****${text.slice(7)}` : text ? '****' : '';
}

export class RepairViews {
  private readonly badRecordLogs = new Set<string>();

  constructor(private readonly now: () => number, private readonly propertyPhone: string,
    private readonly log: (event: object) => void) {}

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
      round: round.number,
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
    }
    // 住户与当前师傅在任务彻底完成（售后期结束）前互相可见电话；物业始终可见。
    if (role !== 'admin' && finished) {
      result.mobile = maskMobile(record.mobile);
      result.workerMobile = maskMobile(record.workerMobile);
    }
    if (role === 'worker') delete result.previousWorkers;
    if (role !== 'admin') {
      result.timeline = events(record).map(event => {
        const visible = { ...event };
        delete visible.previousWorkerId;
        return visible;
      });
    }
    return result;
  }

  listViews(rows: Record<string, unknown>[], role: Role, keep?: (record: RecordData) => boolean): RecordData[] {
    const views: RecordData[] = [];
    for (const row of rows) {
      try {
        const record = JSON.parse(String(row.payload)) as RecordData;
        if (!record || typeof record !== 'object' || Array.isArray(record)) throw new TypeError();
        if (keep && !keep(record)) continue;
        ensureRounds(record);
        views.push(this.view(record, role));
        this.badRecordLogs.delete(`repair_list_record_skipped:${String(row.id)}`);
      } catch (error) {
        this.logBadRecordOnce('repair_list_record_skipped', String(row.id), { role, type: error instanceof Error ? error.name : 'unknown' });
      }
    }
    return views;
  }

}
