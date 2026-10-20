import type { RecordData } from '../database.js';

// 主状态。4 保留给 App 历史上的“已取消”显示，不再写入。
export const Status = { cancelled: 0, pending: 1, processing: 2, completed: 3, assigned: 5, confirming: 6 } as const;

export type Actor = 'resident' | 'worker' | 'admin' | 'system';
export type Event = { action: string; label: string; at: string; by?: Actor; detail?: string; round?: number; previousWorkerId?: string; firstSchedule?: boolean };

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
  proposedSlot?: string;
  firstSchedule?: boolean;
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
export function addEvent(record: RecordData, event: Event) {
  record.timeline = [...events(record), event];
}

export function voidReschedule(record: RecordData, at: string, resolution: string) {
  const open = openPending(record, 'reschedule');
  if (open) Object.assign(open, { resolvedAt: at, resolvedBy: 'system', resolution });
}

// 带本地时区偏移的时间，例如 2026-10-20T10:00:00+08:00；前 10 位就是当地日期。
export const localTimePattern = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?[+-]\d{2}:\d{2}$/;

export type Role = Exclude<Actor, 'system'>;
export const repairItems = [
  { id: '1001', name: '水电维修' }, { id: '1004', name: '水暖维修' }, { id: '1005', name: '电气维修' },
  { id: '1002', name: '门窗五金' }, { id: '1003', name: '其他维修' },
];
export type RepairSkill = 'plumbing' | 'electrical' | 'doors';
export const repairSkills: readonly { id: RepairSkill; name: string }[] = [
  { id: 'plumbing', name: '水暖' }, { id: 'electrical', name: '电气' }, { id: 'doors', name: '门窗五金' },
];
/** 历史水电和其他维修必须由物业明确技能，不能当作任意师傅都能接。 */
export function requiredSkill(record: RecordData): RepairSkill | '' {
  if (repairSkills.some(skill => skill.id === record.requiredSkill)) return record.requiredSkill as RepairSkill;
  return record.repairItemId === '1004' ? 'plumbing' : record.repairItemId === '1005' ? 'electrical' : record.repairItemId === '1002' ? 'doors' : '';
}
