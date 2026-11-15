import type { RecordData } from '../database.js';
import { ApiError, requireValue } from '../errors.js';
import { Status, type RepairSkill } from './model.js';

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const OFFSET = 8 * HOUR;

// 预约规则的唯一来源；客户端只消费查询结果。
export const scheduleRules = {
  hours: [8, 9, 10, 11, 14, 15, 16, 17, 19, 20, 21] as readonly number[],
  days: 7, leadMs: 2 * HOUR, durationMs: HOUR,
  responseMs: 2 * HOUR, minimumResponseMs: 30 * 60_000,
};
export type Capacity = Record<string, number>;
// 方案未指定各时段初始分配：前五段 46，其余 45，默认合计 500，可逐段修改。
export const initialCapacities: Capacity = Object.fromEntries(scheduleRules.hours.map((hour, index) =>
  [String(hour).padStart(2, '0'), index < 5 ? 46 : 45]));

export function validDate(value: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const time = Date.parse(`${value}T00:00:00Z`);
  return Number.isFinite(time) && new Date(time).toISOString().slice(0, 10) === value;
}

export function businessDate(now: number) { return new Date(now + OFFSET).toISOString().slice(0, 10); }
export function availableDates(now: number) {
  const start = Date.parse(`${businessDate(now)}T00:00:00+08:00`);
  return Array.from({ length: scheduleRules.days }, (_, i) => businessDate(start + i * DAY));
}

/** 预约时段编号，例如 2026-10-21#10，表示当天 10 点的时段。 */
export function parseSlot(timeSlot: unknown) {
  if (typeof timeSlot !== 'string' || !/^\d{4}-\d{2}-\d{2}#\d{2}$/.test(timeSlot)) return undefined;
  const [date, hour] = timeSlot.split('#') as [string, string];
  if (!validDate(date) || !scheduleRules.hours.includes(Number(hour))) return undefined;
  const start = `${date}T${hour}:00:00+08:00`;
  const startsAt = Date.parse(start);
  return { code: timeSlot, date, hour, start, startsAt, end: `${date}T${String(Number(hour) + 1).padStart(2, '0')}:00:00+08:00`,
    endsAt: startsAt + scheduleRules.durationMs,
    period: Number(hour) < 12 ? 'morning' : Number(hour) < 18 ? 'afternoon' : 'evening' };
}

/** 旧字段仅接受能精确映射到新时段的带时区整点；绝不向上/向下取整。 */
export function slotFromTime(value: unknown): string {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(?:\.\d{1,3})?)?(?:[+-]\d{2}:\d{2}|Z)$/.test(value)
    || !validDate(value.slice(0, 10))) return '';
  const time = Date.parse(value);
  if (!Number.isFinite(time) || time % HOUR !== 0) return '';
  const local = new Date(time + OFFSET).toISOString();
  const timeSlot = `${local.slice(0, 10)}#${local.slice(11, 13)}`;
  return parseSlot(timeSlot) ? timeSlot : '';
}

export function bookingRejection(timeSlot: string, now: number): string {
  const slot = parseSlot(timeSlot);
  if (!slot) return '请选择有效的上门时段';
  if (!availableDates(now).includes(slot.date)) return '只能预约含今天在内的 7 天';
  if (slot.startsAt - now < scheduleRules.leadMs) return '请至少提前 2 小时预约';
  return '';
}

/** 急单可用当前尚未结束的时段；间歇时刻从下一有效时段开始。 */
export function dispatchSlots(now: number, limit: number) {
  return availableDates(now).flatMap(date => scheduleRules.hours.map(hour => parseSlot(`${date}#${String(hour).padStart(2, '0')}`)!))
    .filter(slot => slot.endsAt > now).slice(0, limit);
}
export function requireDispatchSlot(timeSlot: string, now: number) {
  const slot = parseSlot(timeSlot);
  requireValue(slot && availableDates(now).includes(slot.date) && slot.endsAt > now, '请选择当前尚未结束或未来 7 天内的时段');
}

/** 筛出同一预约时段内未取消的工单；修改已有工单时，排除它自己。 */
export function slotOrders(records: readonly RecordData[], timeSlot: string, excludedRepairId?: string) {
  return records.filter(repair => {
    // 不在这次检查的预约时段内，不参与比较。
    if (repair.slot !== timeSlot) return false;

    // 修改已有工单时，跳过它自己，避免自己与自己冲突。
    if (repair.id === excludedRepairId) return false;

    // 已取消的工单不占名额；4 是历史数据里的取消状态。
    const isCancelled = Number(repair.status) === Status.cancelled || Number(repair.status) === 4;
    if (isCancelled) return false;

    return true;
  });
}
export function occupancy(records: readonly RecordData[], timeSlot: string, excludedRepairId?: string) {
  return slotOrders(records, timeSlot, excludedRepairId).length;
}
/** 检查同一时段是否已有其他工单安排给这位师傅；true 表示时间冲突。 */
export function workerConflict(records: readonly RecordData[], timeSlot: string, workerId: string, excludedRepairId?: string) {
  // 还没有指定师傅，就没有具体的人可以检查。
  if (workerId === '') return false;

  // 先按时间找出工单，再逐张检查它们安排给了谁。
  const otherRepairsInSlot = slotOrders(records, timeSlot, excludedRepairId);
  for (const otherRepair of otherRepairsInSlot) {
    if (otherRepair.workerId === workerId) {
      return true; // 找到一张安排给这位师傅的其他工单，时间冲突。
    }
  }

  return false; // 检查完仍没找到，没有其他工单占用他这个时段。
}
export type WorkerAvailability = { id: string; skills: readonly RepairSkill[]; skillsKnown: boolean; leaves: readonly { date: string; hour: string }[] };
/** 检查预约时段是否落在师傅的请假记录内；true 表示那时请假。 */
export function workerOnLeave(worker: WorkerAvailability, timeSlot: string) {
  // 例如 2026-10-21#10，拆成预约日期 2026-10-21 和小时 10。
  const [appointmentDate, appointmentHour] = timeSlot.split('#');

  for (const leave of worker.leaves) {
    // 其他日期的请假不影响这次预约，继续看下一条记录。
    if (leave.date !== appointmentDate) continue;

    // 请假记录没有指定小时，表示整天请假。
    const isWholeDayLeave = leave.hour === '';
    const isLeaveAtAppointmentHour = leave.hour === appointmentHour;
    if (isWholeDayLeave || isLeaveAtAppointmentHour) {
      return true;
    }
  }

  return false; // 没有任何请假记录覆盖这个预约时段。
}
export function requireFreeWorker(records: readonly RecordData[], timeSlot: string, workerId: string, excludedRepairId?: string) {
  const hasAnotherRepairAtSameTime = workerConflict(records, timeSlot, workerId, excludedRepairId);
  if (hasAnotherRepairAtSameTime) {
    throw new ApiError(409, 40900, '该师傅此时段已有安排');
  }
}

export function slotAvailability(date: string, capacities: Capacity, records: readonly RecordData[], now: number, excludedRepairId?: string,
  context: { workerId?: string; firstSchedule?: boolean } = {}) {
  requireValue(validDate(date), '日期无效');
  return scheduleRules.hours.map(hour => {
    const timeSlot = `${date}#${String(hour).padStart(2, '0')}`;
    const slot = parseSlot(timeSlot)!;
    const capacity = capacities[slot.hour] ?? 0;
    const used = occupancy(records, timeSlot, excludedRepairId);
    const remaining = Math.max(0, capacity - used);
    let reason = bookingRejection(timeSlot, now) || (remaining === 0 ? '该时段已约满' : '');
    if (!reason && context.workerId && workerConflict(records, timeSlot, context.workerId, excludedRepairId)) reason = '该师傅此时段已有安排';
    if (!reason && context.firstSchedule) {
      try { firstProposalDeadline(timeSlot, now); }
      catch (error) { if (!(error instanceof ApiError)) throw error; reason = error.message; }
    }
    return { slot: timeSlot, date, start: slot.start, end: slot.end, period: slot.period, capacity, occupied: used,
      remaining, selectable: reason === '', reason };
  });
}

export function requireAvailable(timeSlot: string, capacities: Capacity, records: readonly RecordData[], now: number,
  excludedRepairId?: string, workerId = '') {
  const reason = bookingRejection(timeSlot, now);
  requireValue(!reason, reason);
  const slot = parseSlot(timeSlot)!;
  if (occupancy(records, timeSlot, excludedRepairId) >= (capacities[slot.hour] ?? 0)) {
    throw new ApiError(409, 40900, '该时段已约满，请重新选择');
  }
  requireFreeWorker(records, timeSlot, workerId, excludedRepairId);
}

export function firstProposalDeadline(timeSlot: string, now: number) {
  const slot = parseSlot(timeSlot);
  requireValue(slot, '请选择有效的上门时段');
  const deadline = Math.min(now + scheduleRules.responseMs, slot.startsAt - scheduleRules.leadMs);
  requireValue(deadline - now >= scheduleRules.minimumResponseMs, '确认时间不足 30 分钟，请选择更晚的时段');
  return new Date(deadline).toISOString();
}

export function setSlot(record: RecordData, timeSlot: string) {
  const slot = parseSlot(timeSlot);
  requireValue(slot, '请选择有效的上门时段');
  record.slot = timeSlot;
  record.agreedTime = slot.start;
  record.autoAccepted = false;
}
export function clearFutureSlot(record: RecordData, now: number) {
  const slot = parseSlot(record.slot);
  if (slot && slot.startsAt > now) record.slot = '';
}

/** 迁移时只映射已有的精确整点约定，非整点/仅日期历史文本原样保留。 */
export function scheduleDefaults(record: RecordData) {
  return { slot: Number(record.status) === Status.cancelled || Number(record.status) === 4 ? '' : slotFromTime(record.agreedTime),
    expectedSlot: slotFromTime(record.expectedTime), priority: '', urgentRequest: false, asap: false,
    autoAccepted: false, shiftCount: 0, needsAdmin: false };
}
