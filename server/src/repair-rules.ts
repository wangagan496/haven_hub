import type { RecordData } from './database.js';

// 主状态。4 保留给 App 历史上的“已取消”显示，不再写入。
export const Status = { cancelled: 0, pending: 1, processing: 2, completed: 3, assigned: 5, confirming: 6 } as const;

const hour = 3_600_000;
// 期限一律按服务端时钟的连续小时计算；集中在此，便于调整和测试注入时钟。
export const rules = {
  autoConfirmMs: 72 * hour,
  warrantyMs: [720 * hour, 480 * hour] as const,
  revokeAutoMs: 2 * hour,
  objectionMs: 72 * hour,
  maxRounds: 2,
  unassignedAlertMs: 24 * hour,
  unacceptedAlertMs: 48 * hour,
  rescheduleAlertMs: 24 * hour,
  rescheduleLeadMs: 2 * hour,
  // “早、中、晚”只是快捷选项和统计分类，住户仍须选择具体时间。
  periods: { morning: [9, 12], noon: [14, 17], evening: [18, 21] } as const,
};

export type Actor = 'resident' | 'worker' | 'admin' | 'system';
export type Event = { action: string; label: string; at: string; by?: Actor; detail?: string; round?: number };

export type Round = {
  number: number;
  reason: string;
  startedAt: string;
  workerId: string;
  workerName: string;
  note: string;
  cost: number | null;
  completedAt: string;
  confirmDeadline: string;
  confirmedAt: string;
  confirmedBy: '' | 'resident' | 'system';
  rejectedAt: string;
  rejectReason: string;
  verifiedNote: string;
};

export type Pending = {
  id: string;
  kind: 'reschedule' | 'revoke' | 'aftersale' | 'feedback';
  by: Actor;
  at: string;
  reason: string;
  proposedTime?: string;
  deadline?: string;
  resolvedAt?: string;
  resolvedBy?: Actor;
  resolution?: string;
  reply?: string;
  objection?: string;
  objectionAt?: string;
};

export function events(record: RecordData): Event[] { return Array.isArray(record.timeline) ? record.timeline as Event[] : []; }
export function rounds(record: RecordData): Round[] { return Array.isArray(record.rounds) ? record.rounds as Round[] : []; }
export function pendings(record: RecordData): Pending[] { return Array.isArray(record.pendings) ? record.pendings as Pending[] : []; }
export function openPending(record: RecordData, kind: Pending['kind']) {
  return pendings(record).find(item => item.kind === kind && !item.resolvedAt);
}

export function newRound(number: number, reason: string, at: string): Round {
  return { number, reason, startedAt: at, workerId: '', workerName: '', note: '', cost: null, completedAt: '',
    confirmDeadline: '', confirmedAt: '', confirmedBy: '', rejectedAt: '', rejectReason: '', verifiedNote: '' };
}

/** 旧数据没有 rounds 字段时补出第一轮，保证后续逻辑只处理一种结构。 */
export function ensureRounds(record: RecordData): Round[] {
  if (!Array.isArray(record.rounds) || record.rounds.length === 0) {
    const first = newRound(1, '首次维修', String(record.createdAt ?? ''));
    if (record.status === Status.completed) {
      first.workerId = String(record.workerId ?? '');
      first.workerName = String(record.workerName ?? '');
      first.note = String(record.completionNote ?? '');
      first.completedAt = String(record.completedAt ?? '');
      first.confirmedAt = String(record.completedAt ?? '');
      first.confirmedBy = 'system';
    }
    record.rounds = [first];
  }
  return record.rounds as Round[];
}

export function currentRound(record: RecordData): Round { return ensureRounds(record).at(-1)!; }
export function reworkUsed(record: RecordData) { return ensureRounds(record).length >= rules.maxRounds; }

// 售后期从最终确认完成起算：第一轮 720 小时，第二轮 480 小时。
export function warrantyEnd(record: RecordData): string {
  if (record.status !== Status.completed) return '';
  const round = currentRound(record);
  const confirmed = Date.parse(round.confirmedAt);
  if (!Number.isFinite(confirmed)) return '';
  const length = rules.warrantyMs[Math.min(round.number, rules.maxRounds) - 1] ?? rules.warrantyMs[1];
  return new Date(confirmed + length).toISOString();
}

export function inWarranty(record: RecordData, now: number) {
  const end = warrantyEnd(record);
  return end !== '' && now < Date.parse(end);
}

/** 任务彻底完成 = 售后期结束（且没有待审核的售后申请）；取消也视为结束。 */
export function closed(record: RecordData, now: number) {
  if (record.status === Status.cancelled) return true;
  return record.status === Status.completed && !inWarranty(record, now) && !openPending(record, 'aftersale');
}

export function addEvent(record: RecordData, event: Event) {
  record.timeline = [...events(record), event];
}

export function voidReschedule(record: RecordData, at: string, resolution: string) {
  const open = openPending(record, 'reschedule');
  if (open) Object.assign(open, { resolvedAt: at, resolvedBy: 'system', resolution });
}

export function applyRevoke(record: RecordData, revoke: Pending, at: string, by: Actor, detail: string) {
  Object.assign(revoke, { resolvedAt: at, resolvedBy: by, resolution: 'approved' });
  voidReschedule(record, at, 'revoked');
  record.status = Status.cancelled;
  record.cancelledAt = at;
  record.objectionDeadline = new Date(Date.parse(at) + rules.objectionMs).toISOString();
  addEvent(record, { action: 'revoked', label: '报修已撤销', at, by, detail });
}

/**
 * 惰性结算到期事项，返回是否有变化。只处理到点必然发生的两件事：
 * 72 小时自动确认，以及撤销申请到时自动通过。改约永远不会自动通过。
 */
export function settle(record: RecordData, now: number): boolean {
  let changed = false;
  if (record.status === Status.confirming) {
    const round = currentRound(record);
    if (round.confirmDeadline && now >= Date.parse(round.confirmDeadline)) {
      round.confirmedAt = round.confirmDeadline;
      round.confirmedBy = 'system';
      record.status = Status.completed;
      addEvent(record, { action: 'auto_confirmed', label: '系统自动确认完成', at: round.confirmDeadline, by: 'system',
        round: round.number, detail: '住户 72 小时内未操作' });
      changed = true;
    }
  }
  const revoke = openPending(record, 'revoke');
  if (revoke?.deadline && now >= Date.parse(revoke.deadline)) {
    applyRevoke(record, revoke, revoke.deadline, 'system', '师傅未在限定时间内回应，撤销自动通过');
    changed = true;
  }
  return changed;
}

/** 物业待办标签：按当前阶段和未处理事项计算，返修过的工单不会因此永久留在待办。 */
export function todoTags(record: RecordData, now: number): string[] {
  const tags: string[] = [];
  const time = (value: unknown) => Date.parse(String(value ?? ''));
  const agreed = time(record.agreedTime);
  if (record.status === Status.pending) {
    const since = time(record.releasedAt ?? record.createdAt);
    if (Number.isFinite(since) && now - since >= rules.unassignedAlertMs) tags.push('超时未派单');
    if (record.releasedAt) tags.push('师傅退出待重派');
  }
  if (record.status === Status.assigned && now - time(record.assignedAt) >= rules.unacceptedAlertMs) tags.push('超时未接单');
  if (record.status === Status.processing) {
    if (Number.isFinite(agreed) && now > agreed) tags.push('约定时间已过仍处理中');
    const round = currentRound(record);
    if (round.number > 1 && round.reason === 'rejected' && !record.agreedTime) tags.push('住户未修好');
  }
  const reschedule = openPending(record, 'reschedule');
  if (reschedule && (now - time(reschedule.at) >= rules.rescheduleAlertMs
    || (Number.isFinite(agreed) && now >= agreed - rules.rescheduleLeadMs))) tags.push('改约待回应');
  if (openPending(record, 'aftersale')) tags.push('售后返修待审核');
  if (openPending(record, 'feedback')) tags.push('问题反馈待回复');
  if (pendings(record).some(item => item.kind === 'revoke' && item.objection && !item.reply)) tags.push('撤销有异议');
  return tags;
}

export function maskMobile(value: unknown) {
  const text = String(value ?? '');
  return /^1\d{10}$/.test(text) ? `${text.slice(0, 3)}****${text.slice(7)}` : text ? '****' : '';
}

// 带本地时区偏移的时间，例如 2026-10-20T10:00:00+08:00；前 10 位就是当地日期。
export const localTimePattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?[+-]\d{2}:\d{2}$/;
