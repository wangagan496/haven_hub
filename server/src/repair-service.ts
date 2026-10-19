import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { RecordData, Store } from './database.js';
import { ApiError, requireValue } from './errors.js';
import {
  Status, rules, type Actor, type Pending, addEvent, applyRevoke, closed, currentRound, ensureRounds, inWarranty,
  localTimePattern, maskMobile, newRound, openPending, pendings, reworkUsed, settle, todoTags, voidReschedule, warrantyEnd,
} from './repair-rules.js';

const revision = z.number().int().min(0);
const reason = z.string().trim().min(1, '请填写原因').max(500);
const optionalNote = z.string().trim().max(1000).default('');
export const localTime = z.string().regex(localTimePattern, '时间格式不正确');
const cost = z.number().min(0).max(1_000_000);

type Role = 'resident' | 'worker' | 'admin';
const ANY_REVISION = -1;
type Loaded = { owner: string; record: RecordData };
const roleLabel: Record<Actor, string> = { resident: '住户', worker: '师傅', admin: '物业', system: '系统' };

/**
 * 报修工单的全部状态流转。
 * 每次读写前先在独立事务中结算到期事项（72 小时自动确认、撤销到时通过），
 * 再在第二个事务中校验 revision 并修改；后续操作 409 或校验失败不会回滚已到期的结算。
 */
export class RepairService {
  private readonly badRecordLogs = new Set<string>();

  constructor(private readonly store: Store, private readonly now: () => number, private readonly propertyPhone: string,
    private readonly log: (event: object) => void = () => {}) {}

  private iso(time = this.now()) { return new Date(time).toISOString(); }

  private logBadRecordOnce(event: 'repair_settlement_failed' | 'repair_list_record_skipped', repairId: string, fields: { role?: Role; type: string }) {
    const key = `${event}:${repairId}`;
    if (this.badRecordLogs.has(key)) return;
    this.badRecordLogs.add(key);
    this.log({ event, repairId, ...fields });
  }

  private load(id: string): Loaded {
    const row = this.store.one('SELECT userId, payload FROM repairs WHERE id = ?', id);
    if (!row) throw new ApiError(404, 40400, '记录不存在或无权访问');
    const record = JSON.parse(String(row.payload)) as RecordData;
    ensureRounds(record);
    return { owner: String(row.userId), record };
  }

  private persistSettlement(loaded: Loaded) {
    if (!settle(loaded.record, this.now())) return;
    loaded.record.revision = Number(loaded.record.revision ?? 0) + 1;
    this.store.save('repairs', loaded.owner, loaded.record, true);
  }

  /** 单条结算，自成一个事务。 */
  private settleOne(id: string) {
    this.store.transaction(() => {
      const row = this.store.one('SELECT id FROM repairs WHERE id = ?', id);
      if (row) this.persistSettlement(this.load(id));
    });
  }

  /** 逐条结算；坏记录在保存点内回滚并记日志，不阻断其他工单或推送队列。 */
  settleAll(filter: { owner?: string; workerId?: string } = {}) {
    this.store.transaction(() => {
      const rows = filter.owner
        ? this.store.db.prepare('SELECT id, userId, payload FROM repairs WHERE userId = ?').all(filter.owner)
        : filter.workerId
          ? this.store.db.prepare("SELECT id, userId, payload FROM repairs WHERE CASE WHEN json_valid(payload) THEN json_extract(payload, '$.workerId') END = ?").all(filter.workerId)
          : this.store.db.prepare('SELECT id, userId, payload FROM repairs').all();
      for (const row of rows) {
        try {
          const processed = this.store.savepoint(() => {
            const record = JSON.parse(String(row.payload)) as RecordData;
            if (filter.workerId && record.workerId !== filter.workerId) return false;
            ensureRounds(record);
            this.persistSettlement({ owner: String(row.userId), record });
            return true;
          });
          if (processed) this.badRecordLogs.delete(`repair_settlement_failed:${String(row.id)}`);
        } catch (error) {
          this.logBadRecordOnce('repair_settlement_failed', String(row.id), { type: error instanceof Error ? error.name : 'unknown' });
        }
      }
    });
  }

  private mutate(id: string, expected: number, guard: (loaded: Loaded) => void, change: (record: RecordData, at: string) => void) {
    this.settleOne(id);
    return this.store.transaction(() => {
      const loaded = this.load(id);
      const current = Number(loaded.record.revision ?? 0);
      const stale = expected !== ANY_REVISION && current !== expected;
      const conflict = () => new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      try {
        guard(loaded);
      } catch (error) {
        // 越权（404/403）优先；通过授权后，旧 revision 的业务拒绝统一按冲突返回，便于客户端刷新。
        if (stale && error instanceof ApiError && error.status === 200) throw conflict();
        throw error;
      }
      if (stale) throw conflict();
      change(loaded.record, this.iso());
      loaded.record.revision = current + 1;
      this.store.save('repairs', loaded.owner, loaded.record, true);
      return loaded;
    });
  }

  private requireOwner(owner: string, userId: string) {
    if (owner !== userId) throw new ApiError(404, 40400, '记录不存在或无权访问');
  }

  private requireWorker(record: RecordData, workerId: string) {
    if (record.workerId !== workerId) throw new ApiError(404, 40400, '工单不存在或未指派给你');
  }

  private user(userId: string) {
    return this.store.one('SELECT nickName, mobile FROM users WHERE id = ?', userId);
  }

  private add(record: RecordData, kind: Pending['kind'], by: Actor, at: string, reasonText: string, extra: Partial<Pending> = {}) {
    record.pendings = [...pendings(record), { id: randomUUID(), kind, by, at, reason: reasonText, ...extra } satisfies Pending];
  }

  // ---------- 视图：按角色裁剪电话并补充派生字段 ----------

  view(record: RecordData, role: Role): RecordData {
    const now = this.now();
    const round = currentRound(record);
    const finished = closed(record, now);
    const result: RecordData = { ...record,
      round: round.number,
      reworkUsed: reworkUsed(record),
      warrantyEnd: warrantyEnd(record),
      confirmDeadline: record.status === Status.confirming ? round.confirmDeadline : '',
      propertyPhone: this.propertyPhone,
      closed: finished,
    };
    if (role === 'admin') result.todo = todoTags(record, now);
    // 住户与当前师傅在任务彻底完成（售后期结束）前互相可见电话；物业始终可见。
    if (role !== 'admin' && finished) {
      result.mobile = maskMobile(record.mobile);
      result.workerMobile = maskMobile(record.workerMobile);
    }
    if (role === 'worker') delete result.previousWorkers;
    return result;
  }

  private respondView(loaded: Loaded, role: Role) { return this.view(loaded.record, role); }

  private listViews(rows: Record<string, unknown>[], role: Role, keep?: (record: RecordData) => boolean): RecordData[] {
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

  // ---------- 住户 ----------

  residentList(userId: string) {
    this.settleAll({ owner: userId });
    const rows = this.store.db.prepare('SELECT id, payload FROM repairs WHERE userId = ? ORDER BY seq DESC').all(userId);
    return this.listViews(rows, 'resident');
  }

  residentDetail(userId: string, id: string) {
    this.settleOne(id);
    const loaded = this.load(id);
    this.requireOwner(loaded.owner, userId);
    return this.view(loaded.record, 'resident');
  }

  confirm(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      this.requireOwner(owner, userId);
      requireValue(record.status === Status.confirming, '当前不是待确认状态');
    }, (record, at) => {
      const round = currentRound(record);
      Object.assign(round, { confirmedAt: at, confirmedBy: 'resident' });
      record.status = Status.completed;
      addEvent(record, { action: 'confirmed', label: '住户确认修好', at, by: 'resident', round: round.number });
    }), 'resident');
  }

  /** 首次维修待确认时反馈未修好：直接回到处理中，原师傅继续负责，消耗唯一一次返修机会。 */
  reject(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      this.requireOwner(owner, userId);
      requireValue(record.status === Status.confirming, '当前不是待确认状态');
      requireValue(!reworkUsed(record), '已返修过一次，请通过“反馈问题”联系物业');
    }, (record, at) => {
      const round = currentRound(record);
      Object.assign(round, { rejectedAt: at, rejectReason: input.reason, confirmDeadline: '' });
      addEvent(record, { action: 'rejected', label: '住户反馈未修好', at, by: 'resident', detail: input.reason, round: round.number });
      this.startRework(record, at, 'rejected');
    }), 'resident');
  }

  /** 已完成且仍在售后期内申请返修，需物业审核。同一工单同时只能有一个待审核申请。 */
  applyAftersale(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      this.requireOwner(owner, userId);
      requireValue(record.status === Status.completed, '只有已完成的工单可以申请售后');
      requireValue(!reworkUsed(record), '已返修过一次，请通过“反馈问题”联系物业');
      requireValue(inWarranty(record, this.now()), '已超过售后期');
      requireValue(!openPending(record, 'aftersale'), '已有待审核的售后申请');
    }, (record, at) => {
      this.add(record, 'aftersale', 'resident', at, input.reason);
      addEvent(record, { action: 'aftersale_applied', label: '住户申请售后返修', at, by: 'resident', detail: input.reason });
    }), 'resident');
  }

  /** 问题反馈：只追加记录，不改主状态，也不会打开新一轮维修。 */
  residentFeedback(userId: string, id: string, raw: unknown) {
    const input = z.object({ revision, content: reason }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      this.requireOwner(owner, userId);
      requireValue(!closed(record, this.now()), '工单已彻底完成，如需帮助请联系物业');
      requireValue(!openPending(record, 'feedback'), '上一条反馈还在等待物业回复');
    }, (record, at) => {
      this.add(record, 'feedback', 'resident', at, input.content);
      addEvent(record, { action: 'feedback', label: '住户反馈问题', at, by: 'resident', detail: input.content });
    }), 'resident');
  }

  /** 未接单前直接撤销；师傅接单后须先电话告知师傅，再提交撤销申请。 */
  revoke(userId: string, id: string, raw: unknown) {
    // 旧客户端只传 id：兼容为未接单前的直接撤销，此时不校验 revision（与旧接口行为一致）。
    const input = z.object({ revision: revision.optional(), reason: reason.default('住户撤销'),
      notified: z.boolean().default(false) }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision ?? ANY_REVISION, ({ owner, record }) => {
      this.requireOwner(owner, userId);
      requireValue(([Status.pending, Status.assigned, Status.processing] as number[]).includes(Number(record.status)),
        '当前阶段不能撤销报修');
      requireValue(!openPending(record, 'revoke'), '已提交撤销申请，等待师傅确认');
      if (record.status === Status.processing) {
        requireValue(input.revision !== undefined, '工单已更新，请刷新后再操作');
        requireValue(input.notified, '请先电话告知师傅，再提交撤销申请');
      }
    }, (record, at) => {
      if (record.status !== Status.processing) {
        record.status = Status.cancelled;
        record.cancelledAt = at;
        addEvent(record, { action: 'cancelled', label: '住户撤销报修', at, by: 'resident', detail: input.reason });
        return;
      }
      const agreed = Date.parse(String(record.agreedTime ?? ''));
      const auto = this.now() + rules.revokeAutoMs;
      const deadline = this.iso(Number.isFinite(agreed) && agreed > this.now() ? Math.min(auto, agreed) : auto);
      this.add(record, 'revoke', 'resident', at, input.reason, { deadline });
      addEvent(record, { action: 'revoke_requested', label: '住户申请撤销（已电话告知师傅）', at, by: 'resident',
        detail: `${input.reason}；师傅在 ${deadline} 前未回应将自动通过` });
    }), 'resident');
  }

  // ---------- 预约 ----------

  /** 任一方发起改约：须先电话告知对方；对方同意后生效，生效前原约定有效，不会自动通过。 */
  propose(userId: string, role: 'resident' | 'worker', id: string, raw: unknown) {
    const input = z.object({ revision, time: localTime, reason,
      notified: z.literal(true, { error: '请先电话告知对方，再发起改约' }) }).strict().parse(raw);
    requireValue(Date.parse(input.time) > this.now(), '新时间必须晚于当前时间');
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      if (role === 'resident') this.requireOwner(owner, userId);
      else this.requireWorker(record, userId);
      requireValue(record.status === Status.processing, '只有处理中的工单可以改约');
      requireValue(!openPending(record, 'reschedule'), '已有待回应的改约，请先处理');
      requireValue(!openPending(record, 'revoke'), '住户已申请撤销，暂不能改约');
    }, (record, at) => {
      this.add(record, 'reschedule', role, at, input.reason, { proposedTime: input.time });
      addEvent(record, { action: 'reschedule_proposed', label: `${roleLabel[role]}提议改约（已电话告知）`, at, by: role,
        detail: `${record.agreedTime || '未约定'} → ${input.time}；${input.reason}` });
    }), role);
  }

  /** 回应改约。师傅一直不回应时，物业跟进后也可以代为回应。 */
  respond(userId: string, role: Role, id: string, raw: unknown) {
    const input = z.object({ revision, accept: z.boolean(), reason: optionalNote }).strict().parse(raw);
    requireValue(input.accept || input.reason.length > 0, '请填写不同意的原因');
    return this.respondView(this.mutate(id, input.revision, ({ owner, record }) => {
      if (role === 'resident') this.requireOwner(owner, userId);
      else if (role === 'worker') this.requireWorker(record, userId);
      const open = openPending(record, 'reschedule');
      requireValue(open, '没有待回应的改约');
      requireValue(role === 'admin' || open.by !== role, '不能回应自己发起的改约');
    }, (record, at) => {
      const open = openPending(record, 'reschedule')!;
      Object.assign(open, { resolvedAt: at, resolvedBy: role, resolution: input.accept ? 'accepted' : 'declined', reply: input.reason });
      if (input.accept) {
        const previous = String(record.agreedTime || '未约定');
        record.agreedTime = open.proposedTime;
        addEvent(record, { action: 'rescheduled', label: `${roleLabel[role]}同意改约`, at, by: role,
          detail: `${previous} → ${open.proposedTime}${input.reason ? `；${input.reason}` : ''}` });
      } else {
        addEvent(record, { action: 'reschedule_declined', label: `${roleLabel[role]}不同意改约，保持原约定`, at, by: role, detail: input.reason });
      }
    }), role);
  }

  // ---------- 师傅 ----------

  workerList(workerId: string) {
    this.settleAll({ workerId });
    const rows = this.store.db.prepare("SELECT id, payload FROM repairs WHERE CASE WHEN json_valid(payload) THEN json_extract(payload, '$.workerId') END = ? ORDER BY seq DESC").all(workerId);
    return this.listViews(rows, 'worker', record => record.workerId === workerId);
  }

  workerDetail(workerId: string, id: string) {
    this.settleOne(id);
    const loaded = this.load(id);
    this.requireWorker(loaded.record, workerId);
    return this.view(loaded.record, 'worker');
  }

  /**
   * 接单时确认上门时间。住户期望时间仍有效时按期望时间生效；
   * 师傅给出不同时间，或期望时间已过，则发起改约提议，等住户同意。
   */
  accept(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, time: localTime.optional(), reason: optionalNote }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      requireValue(record.status === Status.assigned, '该工单已不在待接单状态');
      const expected = String(record.expectedTime || '');
      const expectedValid = expected !== '' && Date.parse(expected) > this.now();
      // 原样提交已过期的期望时间也不能算新的预约。
      if (input.time) requireValue(Date.parse(input.time) > this.now(), '上门时间必须晚于当前时间');
      if (input.time && input.time !== expected) requireValue(input.reason.length > 0, '与住户期望时间不同，请填写原因');
      requireValue(expectedValid || input.time, '住户期望时间已过，请填写新的上门时间');
    }, (record, at) => {
      const expected = String(record.expectedTime || '');
      const expectedValid = expected !== '' && Date.parse(expected) > this.now();
      record.status = Status.processing;
      record.acceptedAt = at;
      record.agreedTime = expectedValid ? expected : '';
      const round = currentRound(record);
      Object.assign(round, { workerId, workerName: String(record.workerName ?? '') });
      addEvent(record, { action: 'accept', label: '师傅接单', at, by: 'worker', round: round.number,
        detail: `${record.workerName}已接单${expectedValid ? `，按住户期望时间 ${expected} 上门` : ''}` });
      if (input.time && input.time !== expected) {
        this.add(record, 'reschedule', 'worker', at, input.reason, { proposedTime: input.time });
        addEvent(record, { action: 'reschedule_proposed', label: '师傅提议上门时间', at, by: 'worker',
          detail: `${record.agreedTime || '未约定'} → ${input.time}；${input.reason}` });
      }
    }), 'worker');
  }

  /** 提交完工：核心只填修了什么、费用多少（无费用填 0）；进入待住户确认，开始 72 小时确认期。 */
  complete(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, result: z.string().trim().max(1000).default(''), cost: cost.default(0) }).strict().parse(raw);
    requireValue(input.result.length > 0, '请填写处理结果后再完成维修');
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      requireValue(record.status === Status.processing, '仅能完成已接单的工单');
      requireValue(!openPending(record, 'revoke'), '住户已申请撤销，请先处理撤销申请');
    }, (record, at) => {
      const round = currentRound(record);
      const deadline = this.iso(this.now() + rules.autoConfirmMs);
      Object.assign(round, { note: input.result, cost: input.cost, completedAt: at, confirmDeadline: deadline,
        workerId, workerName: String(record.workerName ?? '') });
      voidReschedule(record, at, 'completed');
      record.status = Status.confirming;
      record.completedAt = at;
      record.completionNote = input.result;
      addEvent(record, { action: 'complete', label: '师傅提交完工，待住户确认', at, by: 'worker', round: round.number,
        detail: `${input.result}；上报费用 ${input.cost} 元` });
    }), 'worker');
  }

  /** 师傅进展说明（已联系、等待材料等）：只写入时间线，不改主状态。 */
  progress(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, content: reason }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      requireValue(([Status.assigned, Status.processing] as number[]).includes(Number(record.status)), '当前阶段不能补充进展');
    }, (record, at) => {
      addEvent(record, { action: 'progress', label: '师傅进展说明', at, by: 'worker', detail: input.content });
    }), 'worker');
  }

  /** 无法继续接单：填写原因后退出。工单回到待派单，原预约作废，原师傅立即失去访问权限，轮次不变。 */
  release(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    return this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      requireValue(([Status.assigned, Status.processing] as number[]).includes(Number(record.status)), '当前阶段不能退出工单');
    }, (record, at) => {
      record.previousWorkers = [...(Array.isArray(record.previousWorkers) ? record.previousWorkers : []),
        { workerId, workerName: record.workerName, releasedAt: at, reason: input.reason }];
      voidReschedule(record, at, 'released');
      const revokePending = openPending(record, 'revoke');
      if (revokePending) Object.assign(revokePending, { resolvedAt: at, resolvedBy: 'system', resolution: 'released' });
      const round = currentRound(record);
      addEvent(record, { action: 'released', label: '师傅退出，物业正在重新安排', at, by: 'worker', detail: input.reason, round: round.number });
      Object.assign(round, { workerId: '', workerName: '' });
      Object.assign(record, { status: Status.pending, workerId: '', workerName: '', workerMobile: '', agreedTime: '',
        acceptedAt: '', assignedAt: '', releasedAt: at });
    }).record.id;
  }

  /** 师傅回应撤销申请：点“已知晓”，撤销立即生效。 */
  acknowledgeRevoke(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision }).strict().parse(raw);
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      requireValue(openPending(record, 'revoke'), '没有待确认的撤销申请');
    }, (record, at) => {
      applyRevoke(record, openPending(record, 'revoke')!, at, 'worker', '师傅已知晓');
    }), 'worker');
  }

  /** 撤销生效后 72 小时内，师傅可提出异议，由物业与双方沟通；异议不会恢复工单。 */
  objectRevoke(workerId: string, id: string, raw: unknown) {
    const input = z.object({ revision, reason }).strict().parse(raw);
    const approvedRevoke = (record: RecordData) =>
      pendings(record).find(item => item.kind === 'revoke' && item.resolution === 'approved');
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      this.requireWorker(record, workerId);
      const revokeItem = approvedRevoke(record);
      requireValue(record.status === Status.cancelled && revokeItem && !revokeItem.objection, '没有可提出异议的撤销');
      requireValue(this.now() < Date.parse(String(record.objectionDeadline ?? '')), '已超过 72 小时异议期');
    }, (record, at) => {
      Object.assign(approvedRevoke(record)!, { objection: input.reason, objectionAt: at });
      addEvent(record, { action: 'revoke_objected', label: '师傅对撤销有异议，等待物业沟通', at, by: 'worker', detail: input.reason });
    }), 'worker');
  }

  // ---------- 物业 ----------

  adminList() {
    this.settleAll();
    const rows = this.store.db.prepare('SELECT id, payload FROM repairs ORDER BY seq DESC').all();
    return this.listViews(rows, 'admin');
  }

  /** 派单或重新派单。重新派单只更换负责人和联系方式，不重置维修轮次。 */
  assign(id: string, raw: unknown) {
    const input = z.object({ revision, workerId: z.string().uuid() }).strict().parse(raw);
    const worker = this.store.one("SELECT id, nickName, mobile FROM users WHERE id = ? AND role = 'worker'", input.workerId);
    requireValue(worker, '请选择有效的维修人员');
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      requireValue(record.status === Status.pending || record.status === Status.assigned, '只能对未接单的报修派单');
    }, (record, at) => {
      Object.assign(record, { workflowVersion: 1, status: Status.assigned, workerId: input.workerId,
        workerName: String(worker.nickName), workerMobile: String(worker.mobile), assignedAt: at, releasedAt: '' });
      addEvent(record, { action: 'assigned', label: '物业派单', at, by: 'admin', detail: `指派给${worker.nickName}`,
        round: currentRound(record).number });
    }), 'admin');
  }

  /** 审核售后申请。及时提交的申请即使审核时已过售后期仍可通过；拒绝必须填写原因，且不消耗返修机会。 */
  reviewAftersale(id: string, raw: unknown) {
    const input = z.object({ revision, approve: z.boolean(), reason: optionalNote }).strict().parse(raw);
    requireValue(input.approve || input.reason.length > 0, '拒绝售后申请必须填写原因');
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      requireValue(openPending(record, 'aftersale'), '没有待审核的售后申请');
      requireValue(!input.approve || !reworkUsed(record), '已返修过一次，不能再开启返修');
    }, (record, at) => {
      const open = openPending(record, 'aftersale')!;
      Object.assign(open, { resolvedAt: at, resolvedBy: 'admin', resolution: input.approve ? 'approved' : 'rejected', reply: input.reason });
      if (!input.approve) {
        addEvent(record, { action: 'aftersale_rejected', label: '物业拒绝售后申请', at, by: 'admin', detail: input.reason });
        return;
      }
      addEvent(record, { action: 'aftersale_approved', label: '物业通过售后申请，交回原师傅返修', at, by: 'admin',
        detail: [open.reason, input.reason].filter(Boolean).join('；') });
      this.startRework(record, at, 'aftersale');
    }), 'admin');
  }

  /** 物业回复问题反馈、处理撤销异议、记录核实结果或一般跟进；只追加记录，不改主状态。 */
  note(id: string, raw: unknown) {
    const input = z.object({ revision, content: reason, target: z.enum(['feedback', 'objection', 'verify', 'follow']).default('follow'),
      cost: cost.optional(), round: z.number().int().min(1).optional() }).strict().parse(raw);
    // 核实针对已提交完工的一轮：默认最近一轮已完工的，也可指定轮次；不会写到尚未完工的返修轮上。
    const verifiedRound = (record: RecordData) => {
      const done = ensureRounds(record).filter(item => item.completedAt);
      return input.round === undefined ? done.at(-1) : done.find(item => item.number === input.round);
    };
    return this.respondView(this.mutate(id, input.revision, ({ record }) => {
      if (input.target === 'feedback') requireValue(openPending(record, 'feedback'), '没有待回复的问题反馈');
      if (input.target === 'objection') requireValue(pendings(record).some(item => item.objection && !item.reply), '没有待处理的撤销异议');
      if (input.target === 'verify') requireValue(verifiedRound(record), '该轮次尚未提交完工，无法核实');
    }, (record, at) => {
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
      addEvent(record, { action: `admin_${input.target}`, label: target ? `${labels.verify}（第${target.number}轮）` : labels[input.target],
        at, by: 'admin', detail: input.content, ...(target ? { round: target.number } : {}) });
    }), 'admin');
  }

  // ---------- 内部 ----------

  /** 开启第二轮维修：交回上一轮的师傅，撤销上一轮确认期限，原预约作废、重新约时间。 */
  private startRework(record: RecordData, at: string, why: 'rejected' | 'aftersale') {
    const all = ensureRounds(record);
    requireValue(all.length < rules.maxRounds, '已返修过一次，不能再开启返修');
    const previous = all.at(-1)!;
    const worker = previous.workerId ? this.user(previous.workerId) : undefined;
    const round = newRound(all.length + 1, why, at);
    Object.assign(round, { workerId: previous.workerId, workerName: previous.workerName });
    record.rounds = [...all, round];
    voidReschedule(record, at, 'rework');
    Object.assign(record, { status: previous.workerId ? Status.processing : Status.pending, agreedTime: '', completionNote: '',
      workerId: previous.workerId, workerName: previous.workerName || String(worker?.nickName ?? ''),
      workerMobile: String(worker?.mobile ?? record.workerMobile ?? '') });
    addEvent(record, { action: 'rework_started', label: '第二轮维修开始，请重新约定上门时间', at, by: 'system', round: round.number });
  }
}
