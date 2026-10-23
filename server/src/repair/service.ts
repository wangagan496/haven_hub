import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { RecordData, Store } from '../database.js';
import { mobileSchema } from '../auth.js';
import { ApiError, requireValue } from '../errors.js';
import { date, houseInfo } from '../community/resources.js';
import { Status, type Role, addEvent, currentRound, localTimePattern, newRound, openPending, repairItems } from './model.js';
import { eligibility, holdingEligibility, inRepairPool, staffingPlan } from './workforce.js';
import * as actions from './actions.js';
import { ANY_REVISION, RepairRepository, type Loaded } from './repository.js';
import { RepairViews } from './views.js';
import { type Capacity, availableDates, bookingRejection, businessDate, dispatchSlots, parseSlot, requireDispatchSlot, requireFreeWorker, scheduleRules, slotAvailability, slotFromTime } from './schedule.js';
import { activeRepair, compareQueue, shiftRejection, shiftSuggestions, urgentAwaitingDispatch, requireUrgentDispatch } from './policy.js';
import { applyUnstaffedSlot, closeOffer, offerOf, openOffer, unstaffed } from './unstaffed.js';

const revision = z.number().int().min(0);
const weekday = z.string().regex(/^[1-7]$/, '星期必须为 1–7').transform(Number);
const reason = z.string().trim().min(1, '请填写原因').max(500);
const optionalNote = z.string().trim().max(1000).default('');
export const localTime = z.string().regex(localTimePattern, '时间格式不正确');
const cost = z.number().min(0).max(1_000_000);
const slotCode = z.string().refine(value => Boolean(parseSlot(value)), '请选择有效的上门时段');
const capacityValues = z.record(z.string().refine(value => scheduleRules.hours.some(hour => String(hour).padStart(2, '0') === value)),
  z.number().int().min(0).max(1_000_000)).refine(value => Object.keys(value).length > 0, '请至少设置一个时段');

/** 兼容字段名，不兼容任意时间：所有新预约都必须精确匹配服务器时段。 */
function requestSlot(slot?: string, time?: string) {
  const fromTime = time === undefined ? undefined : slotFromTime(time);
  if (time !== undefined) requireValue(fromTime, '上门时间必须是可预约的整点时段');
  if (slot !== undefined && fromTime !== undefined) requireValue(slot === fromTime, '时段与上门时间不一致');
  return slot ?? fromTime;
}

// expectedTime 为住户选择的具体期望上门时间（带时区偏移）；appointment 为其当地日期，兼容旧客户端与旧数据。
export const repairSchema = z.object({
  houseId: z.string().uuid(), repairItemId: z.enum(['1001', '1002', '1003', '1004', '1005']), mobile: mobileSchema,
  appointment: date.optional(), expectedTime: z.string().regex(localTimePattern, '期望上门时间格式不正确').optional(),
  slot: z.union([slotCode, z.literal('')]).optional(), urgentRequest: z.boolean().default(false), asap: z.boolean().default(false),
  description: z.string().trim().max(2000).default(''),
  attachment: z.array(z.url()).max(8).default([]),
}).strict().refine(value => !value.asap || value.urgentRequest, '请先勾选紧急诉求');

/** 校验请求、确认访问权限，并编排仓储与纯动作；不在此实现状态流转。 */
export class RepairService {
  private readonly repository: RepairRepository;
  private readonly views: RepairViews;

  constructor(store: Store, private readonly now: () => number, propertyPhone: string,
    log: (event: object) => void = () => {}, publicBaseUrl = '') {
    this.repository = new RepairRepository(store, now, log, publicBaseUrl);
    this.views = new RepairViews(now, propertyPhone, log);
  }

  settleAll(filter: { owner?: string; workerId?: string } = {}) { this.repository.settleAll(filter); }

  private requireResident(userId: string) {
    if (this.repository.role(userId) !== 'resident') throw new ApiError(403, 40300, '仅工单所属住户可操作');
  }

  unstaffedOptions(userId: string, id: string, admin = false, raw: unknown = {}) {
    if (admin) this.requireAdmin(userId); else this.requireResident(userId);
    const input = z.object({ date: date.optional() }).strict().parse(raw);
    this.repository.settleAll();
    const loaded = this.repository.load(id);
    if (!admin) this.requireOwner(loaded.owner, userId);
    const context = this.repository.staffingContext();
    const options = unstaffed(loaded.record, context) && (admin || openOffer(loaded.record))
      ? this.repository.unstaffedOptions(loaded.record, context) : [];
    const day = input.date ?? businessDate(this.now());
    const slots = admin ? options.slice(0, 3) : options.filter(slot => slot.date === day);
    return { serverTime: new Date(this.now()).toISOString(), today: businessDate(this.now()), date: day, dates: availableDates(this.now()),
      repairId: id, revision: loaded.record.revision, offerId: offerOf(loaded.record)?.id ?? '',
      slots: admin ? slots : slots.map(({ capacity, remaining, eligibleWorkerCount, occupied, ...slot }) => slot),
      ...(admin ? { remainingTotal: slots.reduce((sum, slot) => sum + slot.remaining, 0),
        selectableRemainingTotal: slots.reduce((sum, slot) => sum + slot.remaining, 0) } : {}) };
  }

  unstaffedChoice(userId: string, id: string, raw: unknown) {
    this.requireResident(userId);
    const input = z.union([z.object({ revision, offerId: z.string().min(1), slot: slotCode }).strict(),
      z.object({ revision, offerId: z.string().min(1), keep: z.literal(true) }).strict()]).parse(raw);
    const requireOffer = (record: RecordData) => {
      const offer = openOffer(record);
      if (!offer || offer.id !== input.offerId || Date.parse(offer.deadline) <= this.now()) {
        throw new ApiError(409, 40900, '已过可选时间，物业会联系您');
      }
    };
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => {
        requireOffer(record);
        const context = this.repository.staffingContext();
        if (!unstaffed(record, context)) throw new ApiError(409, 40900, '已过可选时间，物业会联系您');
        if ('keep' in input) closeOffer(record, now, 'resident_kept');
        else {
          if (!this.repository.unstaffedOptions(record, context).some(slot => slot.slot === input.slot))
            throw new ApiError(409, 40900, '该时段刚被约满，请重新选择');
          applyUnstaffedSlot(record, input.slot, now, 'resident');
        }
      }, undefined, requireOffer), 'resident');
  }

  unstaffedReschedule(userId: string, id: string, raw: unknown) {
    this.requireAdmin(userId);
    const input = z.object({ revision, slot: slotCode, notified: z.boolean().optional() }).strict().parse(raw);
    requireValue(input.notified === true, '请先勾选已电话告知住户');
    return this.respondView(this.repository.mutate(id, input.revision, () => this.requireAdmin(userId), (record, now) => {
      const context = this.repository.staffingContext();
      requireValue(unstaffed(record, context), '仅确定无人可接的已约时间工单可使用此操作');
      if (!this.repository.unstaffedOptions(record, context).some(slot => slot.slot === input.slot))
        throw new ApiError(409, 40900, '该时段已不可选');
      applyUnstaffedSlot(record, input.slot, now, 'admin');
    }), 'admin');
  }
  settleWorkforceChange() { this.repository.settleAll({}, this.repository.staffingContext(), true); }
  view(record: RecordData, role: Role) { return this.views.view(record, role); }
  private respondView(loaded: Loaded, role: Role) { return this.view(loaded.record, role); }

  private requireOwner(owner: string, userId: string) {
    if (owner !== userId) throw new ApiError(404, 40400, '记录不存在或无权访问');
  }

  private requireWorker(record: RecordData, workerId: string) {
    if (record.workerId !== workerId) throw new ApiError(404, 40400, '工单不存在或未指派给你');
  }
  residentList(userId: string) {
    this.settleAll({ owner: userId });
    return this.views.listViews(this.repository.residentRows(userId), 'resident');
  }

  residentDetail(userId: string, id: string) {
    this.repository.settleOne(id);
    const loaded = this.repository.load(id);
    this.requireOwner(loaded.owner, userId);
    return this.view(loaded.record, 'resident');
  }

  workerList(workerId: string) {
    this.settleAll({ workerId });
    return this.views.listViews(this.repository.workerRows(workerId), 'worker', record => record.workerId === workerId);
  }

  workerDetail(workerId: string, id: string) {
    this.repository.settleOne(id);
    const loaded = this.repository.load(id);
    this.requireWorker(loaded.record, workerId);
    return this.view(loaded.record, 'worker');
  }

  repairPool(workerId: string) {
    if (this.repository.role(workerId) !== 'worker') throw new ApiError(403, 40300, '仅维修人员可操作');
    const context = this.repository.staffingContext();
    this.repository.settleAll({}, context);
    return [...context.slots.values()].flat().filter(record => context.eligible(record).includes(workerId))
      .sort(compareQueue).map(record => this.views.pool(this.repository.poolLocation(record)));
  }

  claim(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, slot: slotCode.optional() }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => {
      if (this.repository.role(workerId) !== 'worker') throw new ApiError(403, 40300, '仅维修人员可操作');
      if (record.workerId) throw new ApiError(409, 40900, record.assignmentSource === 'pool'
        ? '已被其他师傅接走' : '物业已安排其他师傅');
    }, (record, now) => {
      if (!inRepairPool(record)) throw new ApiError(409, 40900, '此工单已不在可接单列表，请刷新');
      const worker = this.repository.worker(workerId);
      requireValue(worker, '维修人员不存在');
      const why = eligibility(this.repository.workerAvailability().find(item => item.id === workerId), record, String(record.slot ?? ''));
      if (why) throw new ApiError(409, 40900, why);
      if (record.slot) {
        requireValue(!input.slot || input.slot === record.slot, '上门时间不变，请按原时段接单');
        this.repository.checkWorker(String(record.slot), workerId, id, record);
      } else {
        requireValue(input.slot, '请选择首次上门时段');
        this.repository.checkSlot(input.slot, now, id, workerId);
      }
      actions.assign(record, { workerId, worker }, now);
      actions.accept(record, { workerId, slot: input.slot, reason: '师傅接单并提议首次上门时间', pendingId: randomUUID() }, now);
      record.assignmentSource = 'pool';
      addEvent(record, { action: 'pool_claimed', label: '师傅从列表接单', at: new Date(now).toISOString(), by: 'worker' });
    }, () => this.repository.settleWorkforceAfterClaim()), 'worker');
  }

  adminList(): RecordData[] {
    const context = this.repository.staffingContext();
    this.repository.settleAll({}, context);
    return this.views.listViews(this.repository.allRows(), 'admin').map(record => ({ ...record,
      inRepairPool: inRepairPool(record), eligibleWorkerCount: context.eligible(record).length }));
  }

  queue(userId: string) {
    this.requireAdmin(userId);
    return this.adminList().filter(record => activeRepair(record)
      && (record.status === Status.pending || !record.slot || urgentAwaitingDispatch(record))).sort(compareQueue);
  }

  grade(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, priority: z.enum(['urgent', 'medium', 'light']), reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, () => this.requireAdmin(userId),
      (record, now) => actions.grade(record, input, now)), 'admin');
  }

  shiftSuggestions(userId: string, raw: unknown) {
    this.requireAdmin(userId);
    const input = z.object({ date: date.optional() }).strict().parse(raw);
    const rows = this.adminList().filter(record => !input.date || String(record.slot ?? '').startsWith(input.date + '#'));
    return shiftSuggestions(rows, this.now());
  }

  shift(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, slot: slotCode, reason }).strict().parse(raw);
    this.requireAdmin(userId);
    this.repository.settleAll();
    return this.respondView(this.repository.mutate(id, input.revision, () => this.requireAdmin(userId), (record, now) => {
      const rejection = shiftRejection(record, now);
      requireValue(!rejection, rejection);
      this.repository.checkSlot(input.slot, now, record.id, String(record.workerId ?? ''));
      actions.shift(record, input, now);
    }), 'admin');
  }

  dispatchOptions(userId: string, id: string, raw: unknown) {
    this.requireAdmin(userId);
    const input = z.object({ limit: z.coerce.number().int().min(1).max(scheduleRules.days * scheduleRules.hours.length).default(11) }).strict().parse(raw);
    const staffing = this.repository.staffingContext();
    this.repository.settleAll({}, staffing);
    const { record } = this.repository.load(id);
    requireUrgentDispatch(record);
    const now = this.now();
    const workers = this.repository.workers();
    const dates = new Map<string, RecordData[]>();
    const capacities = new Map<string, Capacity>();
    const slots = dispatchSlots(now, input.limit).map(slot => {
      if (!dates.has(slot.date)) dates.set(slot.date, this.repository.scheduledRowsForDate(slot.date));
      if (!capacities.has(slot.date)) capacities.set(slot.date, this.repository.capacities(slot.date).effective);
      const coordination = (record.staffingIssue || record.workforceReturned) && record.agreedTime && record.slot !== slot.code
        ? '人手待协调，调整已约定时间须先走改约确认流程' : '';
      const free = coordination ? [] : workers.filter(worker => !this.repository.staffingReason(slot.code, { ...record, workerId: String(worker.id) }, staffing));
      const { occupied, unassigned, workerCount, shortage } = staffingPlan(dates.get(slot.date)!.filter(row => row.id !== id), slot.code, staffing.workers);
      const reason = coordination || (free.length ? '' : this.repository.staffingReason(slot.code, { ...record, workerId: '' }, staffing) || '该时段暂无可派师傅，请物业协调其他安排');
      return { slot: slot.code, start: slot.start, end: slot.end, current: slot.startsAt <= now,
        occupied, unassigned, workerCount, shortage, reason, dispatchable: !reason, publicCapacity: capacities.get(slot.date)![slot.hour] ?? 0,
        workers: free.map(worker => ({ id: String(worker.id), nickName: String(worker.nickName), mobile: String(worker.mobile) })) };
    });
    return { serverTime: new Date(now).toISOString(), repairId: id, revision: record.revision, slots };
  }

  dispatch(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, workerId: z.string().uuid(), slot: slotCode, reason: optionalNote }).strict().parse(raw);
    this.requireAdmin(userId);
    this.repository.settleAll();
    return this.respondView(this.repository.mutate(id, input.revision, () => this.requireAdmin(userId), (record, now) => {
      requireUrgentDispatch(record);
      requireValue(!(record.staffingIssue || record.workforceReturned) || !record.agreedTime || record.slot === input.slot,
        '人手待协调，调整已约定时间须先走改约确认流程');
      const worker = this.repository.worker(input.workerId);
      requireValue(worker, '请选择有效的维修人员');
      requireDispatchSlot(input.slot, now);
      this.repository.checkWorker(input.slot, input.workerId, record.id, record);
      actions.dispatch(record, { ...input, worker }, now);
    }), 'admin');
  }

  createRepair(userId: string, raw: unknown, readRows = () => this.residentList(userId)) {
    const input = repairSchema.parse(raw);
    const slot = requestSlot(input.slot, input.expectedTime) ?? '';
    requireValue(!input.appointment || Boolean(slot), '请选择具体上门时段，或提交后等待安排');
    requireValue(!input.asap || !slot, '尽快上门不能同时选择时段');
    requireValue(!input.appointment || input.appointment === slot.slice(0, 10), '日期与时段不一致');
    const appointment = slot ? slot.slice(0, 10) : '';
    const id = randomUUID();
    const result = this.repository.create(userId, input.houseId, input.attachment, house => {
      const createdAt = new Date(this.now()).toISOString();
      if (slot) { this.repository.checkSlot(slot, this.now()); this.repository.checkSkillAvailability(slot, { id, repairItemId: input.repairItemId }, id); }
      return { ...input, appointment, expectedTime: slot ? parseSlot(slot)!.start : '', agreedTime: slot ? parseSlot(slot)!.start : '',
        slot, expectedSlot: slot, priority: '', autoAccepted: false, shiftCount: 0, needsAdmin: false,
        id, status: 1, workflowVersion: 1, revision: 1, createdAt,
        roundCount: 1, rounds: [newRound(1, 'first', createdAt)], fees: [], pendings: [],
        timeline: [{ action: 'submitted', label: '住户申请', at: createdAt, by: 'resident',
          detail: slot ? `期望上门时段 ${slot}` : input.asap ? '紧急诉求：尽快上门' : '提交后等待安排' }],
        houseInfo: houseInfo(house), community: String(house.point ?? ''), building: String(house.building ?? ''),
        repairItemName: repairItems.find(item => item.id === input.repairItemId)!.name };
    }, readRows);
    return { ...result, createdId: id };
  }

  /** 旧客户端撤销仍返回完整列表；已到期结算不受后续撤销/列表读取失败影响。 */
  legacyRevoke(userId: string, id: string, raw: unknown) {
    let rows: RecordData[] = [];
    this.revokeRecord(userId, id, raw, () => { rows = this.residentList(userId); });
    return { complete: true, rows, total: rows.length };
  }

  confirm(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => actions.confirm(record, {}, now)), 'resident');
  }

  reject(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => actions.reject(record, { ...input, worker: this.reworkWorker(record) }, now)), 'resident');
  }

  private reworkWorker(record: RecordData) {
    const id = currentRound(record).workerId;
    return { ...this.repository.user(id), qualified: !holdingEligibility(this.repository.workerAvailability().find(worker => worker.id === id), { ...record, workerId: id }) };
  }

  applyAftersale(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => actions.applyAftersale(record, { ...input, pendingId: randomUUID() }, now)), 'resident');
  }

  residentFeedback(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, content: reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => actions.residentFeedback(record, { ...input, pendingId: randomUUID() }, now)), 'resident');
  }

  revoke(userId: string, id: string, raw: unknown) {
    return this.respondView(this.revokeRecord(userId, id, raw), 'resident');
  }

  private revokeRecord(userId: string, id: string, raw: unknown, afterSave?: () => void) {
    // 旧客户端只传 id：兼容为未接单前的直接撤销，此时不校验 revision（与旧接口行为一致）。
    const input = z.object({ revision: revision.optional(), reason: reason.default('住户撤销'),
      notified: z.boolean().default(false) }).strict().parse(raw);
    return this.repository.mutate(id, input.revision ?? ANY_REVISION, ({ owner }) => this.requireOwner(owner, userId),
      (record, now) => actions.revoke(record, { ...input, pendingId: randomUUID() }, now), afterSave);
  }

  propose(userId: string, role: Role, id: string, raw: unknown) {
    const input = z.object({ revision, slot: slotCode.optional(), time: localTime.optional(), reason,
      notified: z.literal(true, { error: '请先电话告知对方，再发起改约' }) }).strict().parse(raw);
    const slot = requestSlot(input.slot, input.time);
    requireValue(slot, '请选择上门时段');
    this.repository.settleAll();
    return this.respondView(this.repository.mutate(id, input.revision, ({ owner, record }) => {
      if (role === 'resident') this.requireOwner(owner, userId);
      else if (role === 'worker') this.requireWorker(record, userId);
      else this.requireAdmin(userId);
    },
      (record, now) => {
        if (!record.slot && !record.agreedTime) this.repository.checkSlot(slot, now, record.id, String(record.workerId ?? ''));
        else {
          const rejection = bookingRejection(slot, now);
          requireValue(!rejection, rejection);
          this.repository.checkSkillAvailability(slot, record, record.id);
        }
        actions.propose(record, { ...input, slot, pendingId: randomUUID(), role }, now);
      }), role);
  }

  respond(userId: string, role: Role, id: string, raw: unknown) {
    const input = z.object({ revision, accept: z.boolean(), reason: optionalNote }).strict().parse(raw);
    requireValue(input.accept || input.reason.length > 0, '请填写不同意的原因');
    this.repository.settleAll();
    let conflict: ApiError | undefined;
    const result = this.repository.mutate(id, input.revision, ({ owner, record }) => {
      if (role === 'resident') this.requireOwner(owner, userId);
      else if (role === 'worker') this.requireWorker(record, userId);
      else this.requireAdmin(userId);
    },
      (record, now) => {
        const proposal = actions.requireRescheduleResponse(record, role);
        if (input.accept) {
          // 历史提议确认也是新安排，必须映射到时段，不能绕开名额约束。
          const target = proposal.proposedSlot || slotFromTime(proposal.proposedTime);
          requireValue(target, '历史改约时间不符合时段规则，请拒绝后重新协商');
          if (proposal.firstSchedule) this.repository.checkWorker(target, String(record.workerId ?? ''), record.id, record);
          else {
            try { this.repository.checkSlot(target, now, record.id, String(record.workerId ?? '')); }
            catch (error) {
              if (!(error instanceof ApiError)) throw error;
              conflict = new ApiError(409, 40900, error.message);
              actions.invalidateProposal(record, error.message, now);
              return;
            }
          }
          proposal.proposedSlot = target;
        }
        actions.respond(record, { ...input, role }, now);
      });
    if (conflict) throw conflict;
    return this.respondView(result, role);
  }

  accept(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, slot: slotCode.optional(), time: localTime.optional(), reason: optionalNote }).strict().parse(raw);
    const slot = requestSlot(input.slot, input.time);
    this.repository.settleAll();
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => {
        const eligibilityReason = holdingEligibility(this.repository.workerAvailability().find(worker => worker.id === workerId), record, String(record.slot ?? ''));
        if (eligibilityReason) throw new ApiError(409, 40900, eligibilityReason);
        if (record.slot) requireFreeWorker(this.repository.scheduledRows(String(record.slot)), String(record.slot), workerId, record.id);
        else if (slot) {
          if (!record.agreedTime) this.repository.checkSlot(slot, now, record.id, workerId);
          else {
            const rejection = bookingRejection(slot, now);
            requireValue(!rejection, rejection);
            this.repository.checkSkillAvailability(slot, record, record.id);
          }
        }
        actions.accept(record, { ...input, slot, pendingId: randomUUID(), workerId }, now);
      }), 'worker');
  }

  complete(workerId: string, id: string, raw: unknown, saveOnly = false) {
    const input = z.object({ revision, result: z.string().trim().max(1000).default(''), cost: cost.default(0),
      ready: saveOnly ? z.boolean() : z.never().optional(),
      problem: z.string().trim().min(1).max(1000).optional(), cause: z.string().trim().min(1).max(1000).optional() }).strict().parse(raw);
    if (!saveOnly || input.ready) requireValue(input.result.length > 0, '请填写处理结果后再完成维修');
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => {
        if (Number(record.roundCount ?? currentRound(record).number) > 1) {
          requireValue(!holdingEligibility(this.repository.workerAvailability().find(worker => worker.id === workerId), { ...record, workerId }), '请由具备对应技能的师傅重新排查，需要时联系物业协调');
        }
        if (saveOnly) actions.saveResult(record, { ...input, workerId, ready: input.ready! }, now);
        else actions.complete(record, { ...input, workerId }, now);
      }), 'worker');
  }

  progress(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, content: reason, needsAdmin: z.boolean().optional() }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => actions.progress(record, { ...input, requestId: randomUUID() }, now)), 'worker');
  }

  release(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => actions.release(record, { ...input, workerId }, now)).record.id;
  }

  acknowledgeRevoke(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => actions.acknowledgeRevoke(record, {}, now)), 'worker');
  }

  objectRevoke(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, ({ record }) => this.requireWorker(record, workerId),
      (record, now) => actions.objectRevoke(record, input, now)), 'worker');
  }

  assign(id: string, raw: unknown) {
    const input = z.object({ revision, workerId: z.string().uuid() }).strict().parse(raw);
    const worker = this.repository.worker(input.workerId);
    requireValue(worker, '请选择有效的维修人员');
    this.repository.settleAll();
    return this.respondView(this.repository.mutate(id, input.revision, () => {},
      (record, now) => {
        const reason = eligibility(this.repository.workerAvailability().find(item => item.id === input.workerId), record);
        if (reason) throw new ApiError(409, 40900, reason);
        if (record.slot) this.repository.checkWorker(String(record.slot), input.workerId, record.id, record);
        actions.assign(record, { ...input, worker }, now);
      }), 'admin');
  }

  classify(userId: string, id: string, raw: unknown) {
    this.requireAdmin(userId);
    const input = z.object({ revision, skill: z.enum(['plumbing', 'electrical', 'doors']), reason }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, () => this.requireAdmin(userId), (record, now) => {
      requireValue(activeRepair(record), '仅可分类未完成工单');
      requireValue(['1001', '1003'].includes(String(record.repairItemId)), '此工单已有明确维修类别');
      record.requiredSkill = input.skill;
      addEvent(record, { action: 'skill_classified', label: '物业明确维修技能', at: new Date(now).toISOString(), by: 'admin', detail: input.reason });
    }), 'admin');
  }

  assignmentOptions(userId: string, id: string) {
    this.requireAdmin(userId);
    const staffing = this.repository.staffingContext();
    this.repository.settleAll({}, staffing);
    const { record } = this.repository.load(id);
    const people = staffing.workers;
    return this.repository.workers().map(worker => {
      const candidate = { ...record, workerId: String(worker.id) };
      const reason = openPending(record, 'revoke') ? '住户已申请撤销，请先处理撤销申请'
        : record.status === Status.processing && worker.id === record.workerId ? '当前维修人员，请选择其他师傅'
        : record.slot ? this.repository.staffingReason(String(record.slot), candidate, staffing)
        : eligibility(people.find(item => item.id === worker.id), candidate);
      return { ...worker, selectable: !reason, reason };
    });
  }

  reviewAftersale(id: string, raw: unknown) {
    const input = z.object({ revision, approve: z.boolean(), reason: optionalNote }).strict().parse(raw);
    requireValue(input.approve || input.reason.length > 0, '拒绝售后申请必须填写原因');
    return this.respondView(this.repository.mutate(id, input.revision, () => {},
      (record, now) => actions.reviewAftersale(record, { ...input, worker: this.reworkWorker(record) }, now)), 'admin');
  }

  note(id: string, raw: unknown) {
    const input = z.object({ revision, content: reason, target: z.enum(['feedback', 'objection', 'verify', 'follow']).default('follow'),
      cost: cost.optional(), round: z.number().int().min(1).optional(), resolveNeedsAdmin: z.boolean().optional() }).strict().parse(raw);
    return this.respondView(this.repository.mutate(id, input.revision, () => {},
      (record, now) => actions.note(record, input, now)), 'admin');
  }

  private requireAdmin(userId: string) {
    if (this.repository.role(userId) !== 'admin') throw new ApiError(403, 40300, '仅物业可以操作');
  }

  slots(userId: string, raw: unknown) {
    const input = z.object({ date: date.optional(), excludeId: z.string().uuid().optional(), repairItemId: z.string().optional() }).strict().parse(raw);
    const now = this.now();
    const day = input.date ?? businessDate(now);
    const staffing = this.repository.staffingContext();
    this.repository.settleAll({ slotDate: day }, staffing);
    let context: { workerId?: string; firstSchedule?: boolean } = {};
    let candidate: RecordData | undefined = input.repairItemId ? { id: '', repairItemId: input.repairItemId, status: Status.pending } : undefined;
    let shiftRecord: RecordData | undefined;
    if (input.excludeId) {
      this.repository.settleOne(input.excludeId, staffing);
      const loaded = this.repository.load(input.excludeId);
      const role = this.repository.role(userId);
      if (role === 'worker' && inRepairPool(loaded.record) && staffing.eligible(loaded.record).includes(userId)) {
        loaded.record = { ...loaded.record, workerId: userId };
      } else if (role === 'worker') this.requireWorker(loaded.record, userId);
      else if (role !== 'admin') this.requireOwner(loaded.owner, userId);
      context = { workerId: String(loaded.record.workerId ?? ''), firstSchedule: !loaded.record.slot && !loaded.record.agreedTime };
      candidate = loaded.record;
      if (role === 'admin') shiftRecord = loaded.record;
    }
    const values = this.repository.capacities(day);
    const slots = slotAvailability(day, values.effective, this.repository.scheduledRowsForDate(day), now, input.excludeId, context).map(slot => {
      if (!candidate) {
        const anySkill = ['1004', '1005', '1002'].some(repairItemId =>
          !this.repository.staffingReason(slot.slot, { id: '', status: Status.pending, repairItemId }, staffing));
        const reason = slot.reason || (anySkill ? '' : '该时段暂无可安排的人手，请提交后等待物业协调');
        return { ...slot, selectable: !reason, reason };
      }
      const reason = slot.reason || this.repository.staffingReason(slot.slot, candidate, staffing);
      return { ...slot, selectable: !reason, reason };
    });
    return { date: day, today: businessDate(now), dates: availableDates(now), serverTime: new Date(now).toISOString(),
      slots: shiftRecord ? slots.map(slot => ({ ...slot, shiftSelectable: slot.selectable && !shiftRejection(shiftRecord!, now)
        && parseSlot(slot.slot)!.startsAt > (parseSlot(shiftRecord!.slot)?.startsAt ?? Infinity) })) : slots,
      remainingTotal: slots.reduce((sum, slot) => sum + slot.remaining, 0),
      selectableRemainingTotal: slots.reduce((sum, slot) => sum + (slot.selectable ? slot.remaining : 0), 0) };
  }

  private capacityView(values: { defaults: Capacity; overrides: Capacity; effective: Capacity; workerCount: number }, date?: string) {
    return { ...values, date: date ?? '', defaultTotal: Object.values(values.defaults).reduce((sum, count) => sum + count, 0),
      effectiveTotal: Object.values(values.effective).reduce((sum, count) => sum + count, 0),
      warnings: Object.entries(values.effective).filter(([, count]) => count > values.workerCount)
        .map(([hour, capacity]) => ({ hour, capacity, message: `${hour}:00 时段容量超过维修人员总数（${values.workerCount}）` })) };
  }

  capacities(userId: string, raw: unknown) {
    this.requireAdmin(userId);
    const input = z.object({ date: date.optional() }).strict().parse(raw);
    return this.capacityView(this.repository.capacities(input.date), input.date);
  }

  saveCapacities(userId: string, raw: unknown, rawDate?: unknown) {
    this.requireAdmin(userId);
    const day = rawDate === undefined ? undefined : date.parse(rawDate);
    const input = z.object({ capacities: capacityValues }).strict().parse(raw);
    return this.capacityView(this.repository.saveCapacities(input.capacities, day), day);
  }

  clearCapacities(userId: string, rawDate: unknown) {
    this.requireAdmin(userId);
    const day = date.parse(rawDate);
    return this.capacityView(this.repository.clearCapacities(day), day);
  }

  weekdayCapacities(userId: string) {
    this.requireAdmin(userId);
    return this.repository.weekdayCapacities();
  }

  saveWeekdayCapacities(userId: string, rawWeekday: unknown, raw: unknown) {
    this.requireAdmin(userId);
    const day = weekday.parse(rawWeekday);
    const input = z.object({ capacities: capacityValues }).strict().parse(raw);
    return this.repository.saveWeekdayCapacities(day, input.capacities);
  }

  clearWeekdayCapacities(userId: string, rawWeekday: unknown) {
    this.requireAdmin(userId);
    return this.repository.clearWeekdayCapacities(weekday.parse(rawWeekday));
  }

}
