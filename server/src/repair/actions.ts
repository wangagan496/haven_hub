import type { RecordData } from '../database.js';
import { requireValue } from '../errors.js';
import { Status, type Actor, type Pending, type Role, addEvent, currentRound, ensureRounds, newRound, openPending, pendings, voidReschedule } from './model.js';
import { activeRepair, applyRevoke, closed, inWarranty, reworkUsed, rules, shiftRejection, requireUrgentDispatch } from './policy.js';
import { clearFutureSlot, firstProposalDeadline, parseSlot, requireDispatchSlot, setSlot } from './schedule.js';

export type WorkerContact = { nickName?: unknown; mobile?: unknown };
const iso = (now: number) => new Date(now).toISOString();
const roleLabel: Record<Actor, string> = { resident: '住户', worker: '师傅', admin: '物业', system: '系统' };

// 时间、待办 ID 和已读取的人员信息由服务层传入；动作不访问数据库或系统时钟。
function addPending(record: RecordData, id: string, kind: Pending['kind'], by: Actor, at: string,
  reasonText: string, extra: Partial<Pending> = {}) {
  record.pendings = [...pendings(record), { id, kind, by, at, reason: reasonText, ...extra } satisfies Pending];
}

export function confirm(record: RecordData, input: Record<string, never>, now: number): void {
  const at = iso(now);
  requireValue(record.status === Status.confirming, '当前不是待确认状态');
  const round = currentRound(record);
  Object.assign(round, { confirmedAt: at, confirmedBy: 'resident' });
  record.status = Status.completed;
  addEvent(record, { action: 'confirmed', label: '住户确认修好', at, by: 'resident', round: round.number });
}

export function reject(record: RecordData, input: { reason: string; worker?: WorkerContact }, now: number): void {
  const at = iso(now);
  requireValue(record.status === Status.confirming, '当前不是待确认状态');
  requireValue(!reworkUsed(record), '已返修过一次，请通过“反馈问题”联系物业');
  const round = currentRound(record);
  Object.assign(round, { rejectedAt: at, rejectReason: input.reason, confirmDeadline: '' });
  addEvent(record, { action: 'rejected', label: '住户反馈未修好', at, by: 'resident', detail: input.reason, round: round.number });
  startRework(record, at, 'rejected', input.worker);
}

export function applyAftersale(record: RecordData, input: { reason: string; pendingId: string }, now: number): void {
  const at = iso(now);
  requireValue(record.status === Status.completed, '只有已完成的工单可以申请售后');
  requireValue(!reworkUsed(record), '已返修过一次，请通过“反馈问题”联系物业');
  requireValue(inWarranty(record, now), '已超过售后期');
  requireValue(!openPending(record, 'aftersale'), '已有待审核的售后申请');
  addPending(record, input.pendingId, 'aftersale', 'resident', at, input.reason);
  addEvent(record, { action: 'aftersale_applied', label: '住户申请售后返修', at, by: 'resident', detail: input.reason });
}

export function residentFeedback(record: RecordData, input: { content: string; pendingId: string }, now: number): void {
  const at = iso(now);
  requireValue(!closed(record, now), '工单已彻底完成，如需帮助请联系物业');
  requireValue(!openPending(record, 'feedback'), '上一条反馈还在等待物业回复');
  addPending(record, input.pendingId, 'feedback', 'resident', at, input.content);
  addEvent(record, { action: 'feedback', label: '住户反馈问题', at, by: 'resident', detail: input.content });
}

export function revoke(record: RecordData, input: { revision?: number; reason: string; notified: boolean; pendingId: string }, now: number): void {
  const at = iso(now);
  requireValue(activeRepair(record), '当前阶段不能撤销报修');
  requireValue(!openPending(record, 'revoke'), '已提交撤销申请，等待师傅确认');
  if (record.status === Status.processing) {
    requireValue(input.revision !== undefined, '工单已更新，请刷新后再操作');
    requireValue(input.notified, '请先电话告知师傅，再提交撤销申请');
  }
  if (record.status !== Status.processing) {
    record.status = Status.cancelled;
    record.cancelledAt = at;
    record.needsAdmin = false;
    voidReschedule(record, at, 'revoked');
    clearFutureSlot(record, now);
    addEvent(record, { action: 'cancelled', label: '住户撤销报修', at, by: 'resident', detail: input.reason });
    return;
  }
  const agreed = Date.parse(String(record.agreedTime ?? ''));
  const auto = now + rules.revokeAutoMs;
  const deadline = iso(Number.isFinite(agreed) && agreed > now ? Math.min(auto, agreed) : auto);
  addPending(record, input.pendingId, 'revoke', 'resident', at, input.reason, { deadline });
  addEvent(record, { action: 'revoke_requested', label: '住户申请撤销（已电话告知师傅）', at, by: 'resident',
    detail: `${input.reason}；师傅在 ${deadline} 前未回应将自动通过` });
}

export function propose(record: RecordData, input: { slot: string; reason: string; role: Role; pendingId: string }, now: number): void {
  const at = iso(now);
  const { role } = input;
  const first = !record.slot && !record.agreedTime;
  requireValue(record.status === Status.processing || ((first || record.workforceReturned) && role === 'admin'
    && (record.status === Status.pending || record.status === Status.assigned)), '当前阶段不能安排上门时间');
  requireValue(!first || role !== 'resident', '待安排工单请等待师傅或物业提出时间');
  requireValue(!openPending(record, 'reschedule'), '已有待回应的改约，请先处理');
  requireValue(!openPending(record, 'revoke'), '住户已申请撤销，暂不能改约');
  const slot = parseSlot(input.slot);
  requireValue(slot, '请选择有效的上门时段');
  const previous = record.agreedTime || '未约定';
  const deadline = first ? firstProposalDeadline(input.slot, now) : undefined;
  // 首次提议只占位；agreedTime 必须等待住户同意或超时生效。
  if (first) Object.assign(record, { slot: input.slot, autoAccepted: false });
  addPending(record, input.pendingId, 'reschedule', role, at, input.reason,
    { proposedTime: slot.start, proposedSlot: input.slot, firstSchedule: first, ...(deadline ? { deadline } : {}) });
  addEvent(record, { action: 'reschedule_proposed', label: `${roleLabel[role]}提议改约（已电话告知）`, at, by: role,
    detail: `${previous} → ${slot.start}；${input.reason}` });
}

/** 服务层在名额检查前调用，纯动作也复用，避免终态工单被回应或写成冲突。 */
export function requireRescheduleResponse(record: RecordData, role: Role): Pending {
  requireValue(activeRepair(record), '当前阶段不能回应改约');
  const open = openPending(record, 'reschedule');
  requireValue(open, '没有待回应的改约');
  requireValue(!open.firstSchedule || role === 'resident', '首次上门时间须由住户确认');
  requireValue(role === 'admin' || open.by !== role, '不能回应自己发起的改约');
  return open;
}

export function respond(record: RecordData, input: { accept: boolean; reason: string; role: Role }, now: number): void {
  const at = iso(now);
  const { role } = input;
  const open = requireRescheduleResponse(record, role);
  Object.assign(open, { resolvedAt: at, resolvedBy: role, resolution: input.accept ? 'accepted' : 'declined', reply: input.reason });
  if (input.accept) {
    const previous = String(record.agreedTime || '未约定');
    if (open.proposedSlot) setSlot(record, open.proposedSlot);
    else record.agreedTime = open.proposedTime; // 仅兼容迁移前已经提出的历史改约。
    addEvent(record, { action: 'rescheduled', label: `${roleLabel[role]}同意改约`, at, by: role,
      detail: `${previous} → ${open.proposedTime}${input.reason ? `；${input.reason}` : ''}` });
  } else {
    if (open.firstSchedule) Object.assign(record, { slot: '', agreedTime: '', autoAccepted: false });
    addEvent(record, { action: 'reschedule_declined', label: open.firstSchedule ? '住户不同意上门时间，等待重新安排' : `${roleLabel[role]}不同意改约，保持原约定`, at, by: role, detail: input.reason });
  }
}

export function accept(record: RecordData, input: { workerId: string; slot?: string; reason: string; pendingId: string }, now: number): void {
  const at = iso(now);
  const { workerId } = input;
  requireValue(record.status === Status.assigned, '该工单已不在待接单状态');
  requireValue(!input.slot || !record.slot || input.slot === record.slot, '请先接单，再发起改约');
  if (input.slot && !record.slot) {
    requireValue(input.reason.length > 0, '请填写上门安排原因');
    if (!record.agreedTime) firstProposalDeadline(input.slot, now);
  }
  record.status = Status.processing;
  record.acceptedAt = at;
  if (record.slot && !openPending(record, 'reschedule')?.firstSchedule) record.agreedTime = parseSlot(record.slot)!.start;
  const round = currentRound(record);
  Object.assign(round, { workerId, workerName: String(record.workerName ?? '') });
  addEvent(record, { action: 'accept', label: '师傅接单', at, by: 'worker', round: round.number,
    detail: `${record.workerName}已接单${openPending(record, 'reschedule')?.firstSchedule ? '，等待住户确认上门时段'
      : record.agreedTime ? `，按已约定时间 ${record.agreedTime} 上门` : '，等待安排上门时间'}` });
  if (input.slot && !record.slot) propose(record, { slot: input.slot, role: 'worker', reason: input.reason, pendingId: input.pendingId }, now);
}

export function complete(record: RecordData, input: { workerId: string; result: string; cost: number }, now: number): void {
  const at = iso(now);
  const { workerId } = input;
  requireValue(record.status === Status.processing, '仅能完成已接单的工单');
  requireValue(!openPending(record, 'revoke'), '住户已申请撤销，请先处理撤销申请');
  const round = currentRound(record);
  const deadline = iso(now + rules.autoConfirmMs);
  Object.assign(round, { note: input.result, cost: input.cost, completedAt: at, confirmDeadline: deadline,
    workerId, workerName: String(record.workerName ?? '') });
  voidReschedule(record, at, 'completed');
  clearFutureSlot(record, now);
  record.status = Status.confirming;
  record.completedAt = at;
  record.completionNote = input.result;
  record.needsAdmin = false;
  addEvent(record, { action: 'complete', label: '师傅提交完工，待住户确认', at, by: 'worker', round: round.number,
    detail: `${input.result}；上报费用 ${input.cost} 元` });
}

export function progress(record: RecordData, input: { content: string; needsAdmin?: boolean; requestId?: string }, now: number): void {
  const at = iso(now);
  requireValue(([Status.assigned, Status.processing] as number[]).includes(Number(record.status)), '当前阶段不能补充进展');
  if (input.needsAdmin) {
    if (!record.needsAdmin) record.adminRequestId = input.requestId;
    record.needsAdmin = true;
  }
  addEvent(record, { action: 'progress', label: input.needsAdmin ? '师傅请求物业协助' : '师傅进展说明', at, by: 'worker', detail: input.content });
}

export function release(record: RecordData, input: { workerId: string; reason: string }, now: number): void {
  const at = iso(now);
  const { workerId } = input;
  requireValue(([Status.assigned, Status.processing] as number[]).includes(Number(record.status)), '当前阶段不能退出工单');
  record.previousWorkers = [...(Array.isArray(record.previousWorkers) ? record.previousWorkers : []),
    { workerId, workerName: record.workerName, releasedAt: at, reason: input.reason }];
  // 首次定时已经占位，退出师傅不替住户作决定；仍允许住户确认/拒绝或到期生效。
  if (!openPending(record, 'reschedule')?.firstSchedule) voidReschedule(record, at, 'released');
  const revokePending = openPending(record, 'revoke');
  if (revokePending) Object.assign(revokePending, { resolvedAt: at, resolvedBy: 'system', resolution: 'released' });
  const round = currentRound(record);
  addEvent(record, { action: 'released', label: '师傅退出，物业正在重新安排', at, by: 'worker', detail: input.reason, round: round.number });
  Object.assign(round, { workerId: '', workerName: '' });
  // 名额属于工单，退出只解除师傅占用，时段及上门时间保留给重新派单。
  Object.assign(record, { status: Status.pending, workerId: '', workerName: '', workerMobile: '',
    acceptedAt: '', assignedAt: '', releasedAt: at });
}

export function acknowledgeRevoke(record: RecordData, input: Record<string, never>, now: number): void {
  const at = iso(now);
  requireValue(openPending(record, 'revoke'), '没有待确认的撤销申请');
  applyRevoke(record, openPending(record, 'revoke')!, at, 'worker', '师傅已知晓');
}

export function objectRevoke(record: RecordData, input: { reason: string }, now: number): void {
  const at = iso(now);
  const approvedRevoke = (record: RecordData) =>
    pendings(record).find(item => item.kind === 'revoke' && item.resolution === 'approved');
  const revokeItem = approvedRevoke(record);
  requireValue(record.status === Status.cancelled && revokeItem && !revokeItem.objection, '没有可提出异议的撤销');
  requireValue(now < Date.parse(String(record.objectionDeadline ?? '')), '已超过 72 小时异议期');
  Object.assign(approvedRevoke(record)!, { objection: input.reason, objectionAt: at });
  addEvent(record, { action: 'revoke_objected', label: '师傅对撤销有异议，等待物业沟通', at, by: 'worker', detail: input.reason });
}

export function assign(record: RecordData, input: { workerId: string; worker: WorkerContact }, now: number): void {
  const at = iso(now);
  const { worker } = input;
  requireValue(record.status === Status.pending || record.status === Status.assigned
    || (record.status === Status.processing && Boolean(record.staffingIssue)), '只能对未接单或人手待协调的报修派单');
  const previousWorkerId = String(record.workerId ?? '');
  if (previousWorkerId && previousWorkerId !== input.workerId) {
    record.previousWorkers = [...(Array.isArray(record.previousWorkers) ? record.previousWorkers : []),
      { workerId: previousWorkerId, workerName: record.workerName, releasedAt: at, reason: '物业改派' }];
    if (!openPending(record, 'reschedule')?.firstSchedule) voidReschedule(record, at, 'reassigned');
  }
  Object.assign(record, { workflowVersion: 1, status: Status.assigned, workerId: input.workerId,
    assignmentSource: 'admin', workforceReturned: false,
    workerName: String(worker.nickName), workerMobile: String(worker.mobile), assignedAt: at, releasedAt: '' });
  addEvent(record, { action: 'assigned', label: '物业派单', at, by: 'admin', detail: `指派给${worker.nickName}`,
    ...(previousWorkerId && previousWorkerId !== input.workerId ? { previousWorkerId } : {}),
    round: currentRound(record).number });
}

export function reviewAftersale(record: RecordData, input: { approve: boolean; reason: string; worker?: WorkerContact }, now: number): void {
  const at = iso(now);
  requireValue(openPending(record, 'aftersale'), '没有待审核的售后申请');
  requireValue(!input.approve || !reworkUsed(record), '已返修过一次，不能再开启返修');
  const open = openPending(record, 'aftersale')!;
  Object.assign(open, { resolvedAt: at, resolvedBy: 'admin', resolution: input.approve ? 'approved' : 'rejected', reply: input.reason });
  if (!input.approve) {
    addEvent(record, { action: 'aftersale_rejected', label: '物业拒绝售后申请', at, by: 'admin', detail: input.reason });
    return;
  }
  addEvent(record, { action: 'aftersale_approved', label: '物业通过售后申请，交回原师傅返修', at, by: 'admin',
    detail: [open.reason, input.reason].filter(Boolean).join('；') });
  startRework(record, at, 'aftersale', input.worker);
}

export function note(record: RecordData, input: { content: string; target: 'feedback' | 'objection' | 'verify' | 'follow'; cost?: number; round?: number; resolveNeedsAdmin?: boolean }, now: number): void {
  const at = iso(now);
  // 核实针对已提交完工的一轮：默认最近一轮已完工的，也可指定轮次；不会写到尚未完工的返修轮上。
  const verifiedRound = (record: RecordData) => {
    const done = ensureRounds(record).filter(item => item.completedAt);
    return input.round === undefined ? done.at(-1) : done.find(item => item.number === input.round);
  };
  if (input.target === 'feedback') requireValue(openPending(record, 'feedback'), '没有待回复的问题反馈');
  if (input.target === 'objection') requireValue(pendings(record).some(item => item.objection && !item.reply), '没有待处理的撤销异议');
  if (input.target === 'verify') requireValue(verifiedRound(record), '该轮次尚未提交完工，无法核实');
  if (input.resolveNeedsAdmin) {
    requireValue(record.needsAdmin, '没有待处理的师傅协助请求');
    record.needsAdmin = false;
  }
  if (input.target === 'feedback') {
    Object.assign(openPending(record, 'feedback')!, { resolvedAt: at, resolvedBy: 'admin', resolution: 'replied', reply: input.content });
  }
  if (input.target === 'objection') {
    Object.assign(pendings(record).find(item => item.objection && !item.reply)!, { reply: input.content });
  }
  // 核实结果单独记录，不覆盖师傅上报的费用；上报、核实、报销是不同概念。
  const target = input.target === 'verify' ? verifiedRound(record)! : undefined;
  if (target) target.verifiedNote = input.cost === undefined ? input.content : `${input.content}（核实费用 ${input.cost} 元）`;
  const labels = { feedback: '物业回复问题反馈', objection: '物业处理撤销异议', verify: '物业核实处理内容和费用', follow: '物业跟进' };
  addEvent(record, { action: `admin_${input.target}`, label: input.resolveNeedsAdmin ? '物业已处理师傅协助请求' : target ? `${labels.verify}（第${target.number}轮）` : labels[input.target],
    at, by: 'admin', detail: input.content, ...(target ? { round: target.number } : {}) });
}

function startRework(record: RecordData, at: string, why: 'rejected' | 'aftersale', worker?: WorkerContact) {
  const all = ensureRounds(record);
  requireValue(all.length < rules.maxRounds, '已返修过一次，不能再开启返修');
  const previous = all.at(-1)!;
  const round = newRound(all.length + 1, why, at);
  Object.assign(round, { workerId: previous.workerId, workerName: previous.workerName });
  record.rounds = [...all, round];
  voidReschedule(record, at, 'rework');
  Object.assign(record, { status: previous.workerId ? Status.processing : Status.pending, slot: '', agreedTime: '', autoAccepted: false, needsAdmin: false, completionNote: '',
    workerId: previous.workerId, workerName: previous.workerName || String(worker?.nickName ?? ''),
    workerMobile: String(worker?.mobile ?? record.workerMobile ?? '') });
  addEvent(record, { action: 'rework_started', label: '第二轮维修开始，请重新约定上门时间', at, by: 'system', round: round.number });
}

/** 改约同意时名额被抢占：保存提议作废状态，由服务层在事务提交后返回 409。 */
export function invalidateProposal(record: RecordData, reason: string, now: number) {
  const at = iso(now);
  voidReschedule(record, at, 'conflict');
  addEvent(record, { action: 'reschedule_voided', label: '改约提议已失效，请重新协商', by: 'system', at, detail: reason });
}

export function grade(record: RecordData, input: { priority: 'urgent' | 'medium' | 'light'; reason: string }, now: number) {
  requireValue(activeRepair(record), '当前阶段不能定级');
  requireValue(input.reason.trim(), '请填写定级原因');
  const previous = String(record.priority || '未定级');
  record.priority = input.priority;
  addEvent(record, { action: 'priority_changed', label: '物业调整等级', at: iso(now), by: 'admin', detail: `${previous} → ${input.priority}；${input.reason}` });
}

export function shift(record: RecordData, input: { slot: string; reason: string }, now: number) {
  const rejection = shiftRejection(record, now);
  requireValue(!rejection, rejection);
  requireValue(input.reason.trim(), '请填写顺延原因');
  const target = parseSlot(input.slot);
  requireValue(target && target.startsAt > parseSlot(record.slot)!.startsAt, '顺延必须选择更晚的时段');
  const previous = String(record.slot);
  voidReschedule(record, iso(now), 'shifted');
  setSlot(record, input.slot);
  record.shiftCount = Number(record.shiftCount ?? 0) + 1;
  addEvent(record, { action: 'admin_shifted', label: '物业顺延上门时间', at: iso(now), by: 'admin', detail: `${previous} → ${input.slot}；${input.reason}` });
}

export function dispatch(record: RecordData, input: { workerId: string; worker: WorkerContact; slot: string; reason: string }, now: number) {
  requireUrgentDispatch(record);
  requireDispatchSlot(input.slot, now);
  const at = iso(now);
  const previousWorkerId = String(record.workerId ?? '');
  const previousWorkerName = String(record.workerName ?? '');
  const firstSchedule = !record.slot && !record.agreedTime;
  const reassigned = previousWorkerId !== '' && previousWorkerId !== input.workerId;
  if (reassigned) {
    record.previousWorkers = [...(Array.isArray(record.previousWorkers) ? record.previousWorkers : []),
      { workerId: previousWorkerId, workerName: previousWorkerName, releasedAt: at, reason: '物业急单改派' }];
  }
  voidReschedule(record, at, 'dispatched');
  setSlot(record, input.slot);
  Object.assign(record, { status: Status.processing, workerId: input.workerId, workerName: String(input.worker.nickName ?? ''),
    workerMobile: String(input.worker.mobile ?? ''), assignedAt: at, acceptedAt: at, releasedAt: '',
    assignmentSource: 'admin', workforceReturned: false });
  Object.assign(currentRound(record), { workerId: record.workerId, workerName: record.workerName });
  addEvent(record, { action: 'urgent_dispatched', label: '物业调度急单，立即生效', at, by: 'admin',
    detail: `${reassigned ? `由 ${previousWorkerName || previousWorkerId} 改派给 ${record.workerName || input.workerId}` : record.workerName}；${input.slot}${input.reason ? `；${input.reason}` : ''}`,
    round: currentRound(record).number, firstSchedule, ...(reassigned ? { previousWorkerId } : {}) });
}
