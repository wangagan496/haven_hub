import type { RecordData } from '../database.js';
import { Status, type Actor, type Pending, addEvent, currentRound, ensureRounds, openPending, pendings, voidReschedule, repairRoundNumber } from './model.js';
import { clearFutureSlot, parseSlot, setSlot } from './schedule.js';
import { requireValue } from '../errors.js';

export function activeRepair(record: RecordData) {
  return ([Status.pending, Status.assigned, Status.processing] as number[]).includes(Number(record.status));
}
export function urgentAwaitingRating(record: RecordData) {
  return activeRepair(record) && record.urgentRequest === true && !record.priority;
}
export function urgentAwaitingDispatch(record: RecordData) {
  return activeRepair(record) && record.priority === 'urgent'
    && (record.status !== Status.processing || !record.workerId || !record.slot || !record.agreedTime
      || Boolean(openPending(record, 'reschedule')?.firstSchedule));
}
export function requireUrgentDispatch(record: RecordData) {
  requireValue(activeRepair(record) && record.priority === 'urgent', '仅可调度物业已定级的未完工急单');
  requireValue(!openPending(record, 'revoke'), '住户已申请撤销，暂不能调度');
}
export function priorityRank(record: RecordData) {
  return record.priority === 'urgent' ? 0 : urgentAwaitingRating(record) ? 1 : record.priority === 'light' ? 3 : 2;
}
export function compareQueue(a: RecordData, b: RecordData) {
  return priorityRank(a) - priorityRank(b) || String(a.createdAt ?? '').localeCompare(String(b.createdAt ?? ''))
    || a.id.localeCompare(b.id);
}
export function shiftRejection(record: RecordData, now: number): string {
  if (!activeRepair(record)) return '当前阶段不能顺延';
  if (record.staffingIssue && (parseSlot(record.slot)?.startsAt ?? Infinity) <= now) return '该时段已开始，请改派';
  if (!record.agreedTime || pendings(record).some(item => item.kind === 'reschedule' && item.firstSchedule && !item.resolvedAt)) {
    return '首次上门时间尚未确认，请等待住户回应或重新提议';
  }
  const slot = parseSlot(record.slot);
  if (!slot) return '工单尚无有效时段，请先安排';
  if (slot.startsAt <= now) return '已开始的时段不能顺延';
  if (openPending(record, 'revoke')) return '住户已申请撤销，暂不能顺延';
  return '';
}
/** 仅给提示，不修改工单；已开始的候选保留禁用原因。 */
export function shiftSuggestions(records: RecordData[], now: number) {
  return records.filter(record => activeRepair(record) && parseSlot(record.slot)).sort((a, b) =>
    Number(a.priority !== 'light') - Number(b.priority !== 'light')
    || Number(parseSlot(a.slot)!.startsAt <= now) - Number(parseSlot(b.slot)!.startsAt <= now)
    || Number(Number(a.shiftCount ?? 0) !== 0) - Number(Number(b.shiftCount ?? 0) !== 0)
    || parseSlot(b.slot)!.startsAt - parseSlot(a.slot)!.startsAt
    || compareQueue(a, b))
    .map(record => ({ ...record, canShift: !shiftRejection(record, now), shiftReason: shiftRejection(record, now) }));
}

const hour = 3_600_000;
// 期限一律按服务端时钟的连续小时计算；集中在此，便于调整和测试注入时钟。
export const rules = {
  autoConfirmMs: 72 * hour,
  warrantyMs: 720 * hour,
  revokeAutoMs: 2 * hour,
  objectionMs: 72 * hour,
  unassignedAlertMs: 24 * hour,
  unacceptedAlertMs: 48 * hour,
  rescheduleAlertMs: 24 * hour,
  rescheduleLeadMs: 2 * hour,
  // “早、中、晚”只是快捷选项和统计分类，住户仍须选择具体时间。
  periods: { morning: [9, 12], noon: [14, 17], evening: [18, 21] } as const,
};

export function reworkUsed(record: RecordData) { return repairRoundNumber(record) > 1; }

// 每一轮售后期均从最终确认完成起算 720 小时，返修次数不设上限。
export function warrantyEnd(record: RecordData): string {
  if (record.status !== Status.completed) return '';
  const round = currentRound(record);
  const confirmed = Date.parse(round.confirmedAt);
  if (!Number.isFinite(confirmed)) return '';
  return new Date(confirmed + rules.warrantyMs).toISOString();
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

export function applyRevoke(record: RecordData, revoke: Pending, at: string, by: Actor, detail: string) {
  Object.assign(revoke, { resolvedAt: at, resolvedBy: by, resolution: 'approved' });
  voidReschedule(record, at, 'revoked');
  record.status = Status.cancelled;
  record.needsAdmin = false;
  record.cancelledAt = at;
  clearFutureSlot(record, Date.parse(at));
  record.objectionDeadline = new Date(Date.parse(at) + rules.objectionMs).toISOString();
  addEvent(record, { action: 'revoked', label: '报修已撤销', at, by, detail });
}

/**
 * 惰性结算确认、撤销及首次定时期限；已有安排的改约永不自动通过。
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
  const proposal = openPending(record, 'reschedule');
  if (!record.staffingIssue && proposal?.firstSchedule && proposal.deadline && proposal.proposedSlot
    && activeRepair(record)
    && now >= Date.parse(proposal.deadline)) {
    // 提议时已持有名额和师傅时段；到期只确认，不重新竞争名额。
    setSlot(record, proposal.proposedSlot);
    record.autoAccepted = true;
    Object.assign(proposal, { resolvedAt: proposal.deadline, resolvedBy: 'system', resolution: 'auto_accepted' });
    addEvent(record, { action: 'schedule_auto_accepted', label: '上门时间超时已生效', at: proposal.deadline, by: 'system',
      detail: `${record.agreedTime}；住户未主动确认，请先电话确认` });
    changed = true;
  }
  return changed;
}

/** 物业待办标签：按当前阶段和未处理事项计算，返修过的工单不会因此永久留在待办。 */
export function todoTags(record: RecordData, now: number): string[] {
  const tags: string[] = [];
  if (urgentAwaitingDispatch(record)) tags.push('急单待调度');
  if (urgentAwaitingRating(record)) tags.push('紧急诉求待定级');
  if (activeRepair(record) && record.needsAdmin) tags.push('师傅请求物业协助');
  if (activeRepair(record) && record.staffingIssue) tags.push('人手待协调');
  if (activeRepair(record) && record.poolShortage) tags.push('可接单时段缺人');
  if (openPending(record, 'reschedule')?.firstSchedule) tags.push('等待确认时间');
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
