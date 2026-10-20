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

export function parseSlot(code: unknown) {
  if (typeof code !== 'string' || !/^\d{4}-\d{2}-\d{2}#\d{2}$/.test(code)) return undefined;
  const [date, hour] = code.split('#') as [string, string];
  if (!validDate(date) || !scheduleRules.hours.includes(Number(hour))) return undefined;
  const start = `${date}T${hour}:00:00+08:00`;
  const startsAt = Date.parse(start);
  return { code, date, hour, start, startsAt, end: `${date}T${String(Number(hour) + 1).padStart(2, '0')}:00:00+08:00`,
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
  const code = `${local.slice(0, 10)}#${local.slice(11, 13)}`;
  return parseSlot(code) ? code : '';
}

export function bookingRejection(code: string, now: number): string {
  const slot = parseSlot(code);
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
export function requireDispatchSlot(code: string, now: number) {
  const slot = parseSlot(code);
  requireValue(slot && availableDates(now).includes(slot.date) && slot.endsAt > now, '请选择当前尚未结束或未来 7 天内的时段');
}

/** 所有名额和师傅冲突检查共用这一个有效占用筛选函数。 */
export function slotOrders(records: readonly RecordData[], code: string, excludeId?: string) {
  return records.filter(record => record.id !== excludeId && record.slot === code
    && Number(record.status) !== Status.cancelled && Number(record.status) !== 4);
}
export function occupancy(records: readonly RecordData[], code: string, excludeId?: string) {
  return slotOrders(records, code, excludeId).length;
}
export function workerConflict(records: readonly RecordData[], code: string, workerId: string, excludeId?: string) {
  return workerId !== '' && slotOrders(records, code, excludeId).some(record => record.workerId === workerId);
}
export type WorkerAvailability = { id: string; skills: readonly RepairSkill[]; skillsKnown: boolean; leaves: readonly { date: string; hour: string }[] };
export function workerOnLeave(worker: WorkerAvailability, code: string) {
  const [date, hour] = code.split('#');
  return worker.leaves.some(leave => leave.date === date && (leave.hour === '' || leave.hour === hour));
}
export function requireFreeWorker(records: readonly RecordData[], code: string, workerId: string, excludeId?: string) {
  if (workerConflict(records, code, workerId, excludeId)) throw new ApiError(409, 40900, '该师傅此时段已有安排');
}

export function slotAvailability(date: string, capacities: Capacity, records: readonly RecordData[], now: number, excludeId?: string,
  context: { workerId?: string; firstSchedule?: boolean } = {}) {
  requireValue(validDate(date), '日期无效');
  return scheduleRules.hours.map(hour => {
    const code = `${date}#${String(hour).padStart(2, '0')}`;
    const slot = parseSlot(code)!;
    const capacity = capacities[slot.hour] ?? 0;
    const used = occupancy(records, code, excludeId);
    const remaining = Math.max(0, capacity - used);
    let reason = bookingRejection(code, now) || (remaining === 0 ? '该时段已约满' : '');
    if (!reason && context.workerId && workerConflict(records, code, context.workerId, excludeId)) reason = '该师傅此时段已有安排';
    if (!reason && context.firstSchedule) {
      try { firstProposalDeadline(code, now); }
      catch (error) { if (!(error instanceof ApiError)) throw error; reason = error.message; }
    }
    return { slot: code, date, start: slot.start, end: slot.end, period: slot.period, capacity, occupied: used,
      remaining, selectable: reason === '', reason };
  });
}

export function requireAvailable(code: string, capacities: Capacity, records: readonly RecordData[], now: number,
  excludeId?: string, workerId = '') {
  const reason = bookingRejection(code, now);
  requireValue(!reason, reason);
  const slot = parseSlot(code)!;
  if (occupancy(records, code, excludeId) >= (capacities[slot.hour] ?? 0)) {
    throw new ApiError(409, 40900, '该时段已约满，请重新选择');
  }
  requireFreeWorker(records, code, workerId, excludeId);
}

export function firstProposalDeadline(code: string, now: number) {
  const slot = parseSlot(code);
  requireValue(slot, '请选择有效的上门时段');
  const deadline = Math.min(now + scheduleRules.responseMs, slot.startsAt - scheduleRules.leadMs);
  requireValue(deadline - now >= scheduleRules.minimumResponseMs, '确认时间不足 30 分钟，请选择更晚的时段');
  return new Date(deadline).toISOString();
}

export function setSlot(record: RecordData, code: string) {
  const slot = parseSlot(code);
  requireValue(slot, '请选择有效的上门时段');
  record.slot = code;
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
