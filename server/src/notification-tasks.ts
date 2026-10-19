import type { RecordData } from './database.js';
import { Status, currentRound, pendings } from './repair-rules.js';

export type NotificationTask = { key: string; userId: string; role: 'resident' | 'worker' | 'admin'; title: string; body: string };

/** Dismissing or reading a notification never resolves the underlying repair task. */
export function repairNotificationTasks(record: RecordData, owner: string, admins: string[]): NotificationTask[] {
  const result: NotificationTask[] = [];
  const worker = String(record.workerId ?? '');
  const add = (key: string, userId: string, role: NotificationTask['role'], body: string) => {
    if (userId) result.push({ key, userId, role, title: '报修待处理', body });
  };
  const admin = (key: string, body: string) => admins.forEach(id => add(key, id, 'admin', body));
  if (record.status === Status.pending) admin('assignment', '有报修等待派单，请查看工单。');
  if (record.status === Status.assigned) add('accept:' + worker, worker, 'worker', '有新的报修派给你，请查看并接单。');
  if (record.status === Status.confirming) add('confirm:' + currentRound(record).number, owner, 'resident', '师傅已提交维修结果，请确认是否修好。');
  if (record.status === Status.processing && currentRound(record).number > 1 && !record.agreedTime) {
    add('rework:' + currentRound(record).number, worker, 'worker', '工单已进入返修，请联系住户重新约定上门时间。');
  }
  for (const pending of pendings(record)) {
    if (!pending.resolvedAt) {
      const key = pending.kind + ':' + pending.id;
      if (pending.kind === 'reschedule') add(key, pending.by === 'worker' ? owner : worker, pending.by === 'worker' ? 'resident' : 'worker', '有上门时间调整等待你的确认。');
      else if (pending.kind === 'revoke') add(key, worker, 'worker', '住户申请撤销报修，请查看并回应。');
      else if (pending.kind === 'aftersale') admin(key, '有售后返修申请等待审核。');
      else if (pending.kind === 'feedback') admin(key, '住户提交了问题反馈，请查看并回复。');
    }
    if (pending.objection && !pending.reply) admin('objection:' + pending.id, '有报修撤销异议等待处理。');
  }
  return result;
}
