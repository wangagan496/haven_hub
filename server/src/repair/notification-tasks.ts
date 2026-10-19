import type { RecordData } from '../database.js';
import { Status, currentRound, events, pendings } from './model.js';
import { activeRepair, urgentAwaitingDispatch, urgentAwaitingRating } from './policy.js';

export type NotificationTask = { key: string; userId: string; role: 'resident' | 'worker' | 'admin'; title: string; body: string };

export function notificationKind(taskKey: string): 'info' | 'task' {
  return /^(time_adjusted|schedule_auto_accepted|worker_reassigned):/.test(taskKey) ? 'info' : 'task';
}

/** Dismissing or reading a notification never resolves the underlying repair task. */
export function repairNotificationTasks(record: RecordData, owner: string, admins: string[]): NotificationTask[] {
  const result: NotificationTask[] = [];
  const worker = String(record.workerId ?? '');
  const add = (key: string, userId: string, role: NotificationTask['role'], body: string, title = '报修待处理') => {
    if (userId) result.push({ key, userId, role, title, body });
  };
  const admin = (key: string, body: string, title = '报修待处理') => admins.forEach(id => add(key, id, 'admin', body, title));
  if (urgentAwaitingDispatch(record)) admin('urgent_dispatch', '急单等待物业指定师傅和时段，请优先处理。', '急单待调度');
  if (urgentAwaitingRating(record)) admin('urgent_request', '住户提出紧急诉求，请核实并确定工单等级。', '紧急诉求待定级');
  // 仅保留本次改派的告知；下一次业务变更追加事件后，或工单结束后关闭。
  const timeline = events(record);
  const latest = timeline.at(-1);
  if (activeRepair(record) && latest?.action === 'urgent_dispatched' && latest.previousWorkerId
    && latest.previousWorkerId !== worker) {
    add(`worker_reassigned:${timeline.length - 1}`, latest.previousWorkerId, 'worker',
      '工单已由物业改派，无需上门', '工单已由物业改派，无需上门');
  }
  if (activeRepair(record) && record.needsAdmin) {
    admin('assistance:' + String(record.adminRequestId ?? 'legacy'), '师傅请求物业协助，请查看进展并跟进处理。', '师傅请求物业协助');
  }
  // 保留当前安排的最新提醒；新安排、返修、取消或完工后旧提醒关闭。
  if (activeRepair(record) && record.slot && record.agreedTime) {
    const index = timeline.findLastIndex(event => ['rescheduled', 'admin_shifted', 'urgent_dispatched', 'schedule_auto_accepted'].includes(event.action));
    if (index >= 0) {
      const event = timeline[index]!;
      const auto = event.action === 'schedule_auto_accepted' && record.autoAccepted;
      const title = auto ? '超时已生效' : '时间已调整';
      const body = auto ? `上门时间 ${record.agreedTime} 已超时生效，住户未主动确认，请先电话确认。`
        : `上门时间已调整为 ${record.agreedTime}。${event.detail ?? ''}`;
      const key = `${auto ? 'schedule_auto_accepted' : 'time_adjusted'}:${index}`;
      add(key, owner, 'resident', body, title);
      add(key, worker, 'worker', body, title);
    }
  }
  if (record.status === Status.pending) admin('assignment', '有报修等待派单，请查看工单。');
  if (record.status === Status.assigned) add('accept:' + worker, worker, 'worker', '有新的报修派给你，请查看并接单。');
  if (record.status === Status.confirming) add('confirm:' + currentRound(record).number, owner, 'resident', '师傅已提交维修结果，请确认是否修好。');
  if (record.status === Status.processing && currentRound(record).number > 1 && !record.agreedTime) {
    add('rework:' + currentRound(record).number, worker, 'worker', '工单已进入返修，请联系住户重新约定上门时间。');
  }
  for (const pending of pendings(record)) {
    if (!pending.resolvedAt) {
      const key = pending.kind + ':' + pending.id;
      if (pending.kind === 'reschedule') {
        if (pending.firstSchedule || pending.by !== 'resident') add(key, owner, 'resident',
          pending.firstSchedule ? `请确认首次上门时段 ${pending.proposedSlot}，确认期限 ${pending.deadline}。` : '有上门时间调整等待你的确认。',
          pending.firstSchedule ? '等待确认时间' : '报修待处理');
        if (!pending.firstSchedule && pending.by !== 'worker') add(key, worker, 'worker', '有上门时间调整等待你的确认。');
      }
      else if (pending.kind === 'revoke') add(key, worker, 'worker', '住户申请撤销报修，请查看并回应。');
      else if (pending.kind === 'aftersale') admin(key, '有售后返修申请等待审核。');
      else if (pending.kind === 'feedback') admin(key, '住户提交了问题反馈，请查看并回复。');
    }
    if (pending.objection && !pending.reply) admin('objection:' + pending.id, '有报修撤销异议等待处理。');
  }
  return result;
}
