import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store, type RecordData } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { mobileSchema } from './auth.js';
import { scheduleRules, validDate } from './repair/schedule.js';
import { inRepairPool, readWorkforce, StaffingContext, workforceOrderSummary } from './repair/workforce.js';
import { workforceImpact } from './repair/workforce-change.js';
import { activeRepair } from './repair/policy.js';
import { ManagementAudit, type AuditTarget } from './management-audit.js';

const revision = z.number().int().min(0);
const note = z.string().trim().max(1000);
const leaveDate = z.string().refine(validDate, '休假日期无效');
const leaveHour = z.string().refine(value => value === '' || scheduleRules.hours.some(hour => String(hour).padStart(2, '0') === value), '休假时段无效').default('');

type SkillPreview = {
  actorId: string; workerId: string; revision: number; skills: string;
  signature: string; expiresAt: number;
  orders: { id: string; revision: number; workerId: string; status: number }[];
};

const SKILL_PREVIEW_ACTOR_LIMIT = 8;
const SKILL_PREVIEW_TOTAL_LIMIT = 256;

/** 角色校验、房屋审核和维修人员名册。报修工单流转见 repair/service.ts。 */
export class WorkflowService {
  // 短期、有限数量的确认凭据；重启或过期后必须重新预览。
  private readonly skillPreviews = new Map<string, SkillPreview>();
  private readonly audit: ManagementAudit;
  constructor(private readonly store: Store, private readonly now: () => number = Date.now,
    private readonly workforceChanged: () => void = () => {}) {
    this.audit = new ManagementAudit(store, now);
  }

  requireRole(userId: string, role: 'admin' | 'worker') {
    if (this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role !== role) {
      throw new ApiError(403, 40300, role === 'admin' ? '仅物业管理员可操作' : '仅维修人员可操作');
    }
  }

  role(userId: string) {
    return String(this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role ?? '');
  }

  rooms(): RecordData[] {
    return this.store.db.prepare('SELECT payload FROM rooms ORDER BY seq DESC').all()
      .map(row => JSON.parse(String(row.payload)) as RecordData);
  }

  workers() {
    const rows = this.store.db.prepare("SELECT id, nickName, mobile, disabledAt, workforceRevision AS revision FROM users WHERE role = 'worker' ORDER BY nickName").all();
    return rows.map(row => ({ ...row, id: String(row.id), revision: Number(row.revision),
      skillChange: this.store.one('SELECT actorId, actorName, changedAt FROM worker_skill_audit WHERE workerId=?', String(row.id)) ?? null,
      skills: this.store.db.prepare('SELECT skill FROM worker_skills WHERE workerId=? ORDER BY skill').all(String(row.id)).map(item => String(item.skill)),
      leaves: this.store.db.prepare('SELECT date,hour,reason FROM worker_leaves WHERE workerId=? ORDER BY date,hour').all(String(row.id)),
    }));
  }

  workforceSummary() {
    return { unregisteredCount: Number(this.store.one("SELECT COUNT(*) AS count FROM users u WHERE role='worker' AND disabledAt=0 AND NOT EXISTS (SELECT 1 FROM worker_skills s WHERE s.workerId=u.id)")!.count) };
  }

  setWorkerEnabled(workerId: string, raw: unknown, actorId: string) {
    this.requireRole(actorId, 'admin');
    const input = z.object({ revision, enabled: z.boolean(), reason: note.min(1) }).strict().parse(raw);
    return this.store.transaction(() => {
      const worker = this.store.one("SELECT workforceRevision,disabledAt FROM users WHERE id=? AND role='worker'", workerId);
      if (!worker) throw new ApiError(404, 40400, '维修人员不存在');
      if (Number(worker.workforceRevision) !== input.revision) throw new ApiError(409, 40900, '人员安排已更新，请刷新后再操作');
      const enabled = Number(worker.disabledAt) === 0;
      const target: AuditTarget = { type: 'worker', id: workerId };
      const before = this.audit.snapshot(target);
      if (enabled === input.enabled) throw new ApiError(409, 40900, '账号状态已更新，请刷新后再操作');
      if (!input.enabled) {
        const assigned = this.store.db.prepare("SELECT payload FROM repairs WHERE CASE WHEN json_valid(payload) THEN json_extract(payload,'$.workerId') END=?").all(workerId);
        const pending = assigned.some(row => {
          const record = JSON.parse(String(row.payload)) as RecordData;
          return activeRepair(record) || record.status === 6 ||
            (Array.isArray(record.pendings) && record.pendings.some(item => !item.resolvedAt));
        });
        requireValue(!pending, '该师傅仍有待处理工单，请先改派或完成待办后再停用');
      }
      this.store.run('UPDATE users SET disabledAt=?,workforceRevision=workforceRevision+1 WHERE id=?', input.enabled ? 0 : Math.max(1, this.now()), workerId);
      // Re-enabling never restores old credentials or notification registrations.
      this.store.run('DELETE FROM sessions WHERE userId=?', workerId);
      this.store.run('DELETE FROM codes WHERE mobile=(SELECT mobile FROM users WHERE id=?)', workerId);
      this.store.run("UPDATE push_deliveries SET status='cancelled',lease='' WHERE status IN ('queued','failed','sending','unconfigured') AND notificationId IN (SELECT id FROM notifications WHERE userId=?)", workerId);
      this.store.run('UPDATE notifications SET active=0 WHERE userId=?', workerId);
      this.store.run('DELETE FROM push_devices WHERE userId=?', workerId);
      this.store.run('INSERT INTO account_events(userId,actorId,enabled,reason,createdAt) VALUES (?,?,?,?,?)',
        workerId, actorId, Number(input.enabled), input.reason, this.now());
      this.workforceChanged();
      this.audit.append({ actorId, action: 'worker.access' }, target, before);
      return this.workers();
    });
  }

  workerAccountEvents(workerId: string, actorId: string, raw: unknown) {
    this.requireRole(actorId, 'admin');
    const input = z.object({ before: z.coerce.number().int().positive().optional() }).strict().parse(raw);
    if (!this.store.one("SELECT id FROM users WHERE id=? AND role='worker'", workerId)) throw new ApiError(404, 40400, '维修人员不存在');
    return this.store.db.prepare(`SELECT seq,actorId,enabled,reason,createdAt FROM account_events
      WHERE userId=? AND seq<? ORDER BY seq DESC LIMIT 50`).all(workerId, input.before ?? Number.MAX_SAFE_INTEGER);
  }

  saveWorker(raw: unknown, actorId: string) {
    this.requireRole(actorId, 'admin');
    const input = z.object({ mobile: mobileSchema, nickName: z.string().trim().min(2).max(20),
      revision: revision.optional() }).strict().parse(raw);
    return this.store.transaction(() => {
      const existing = this.store.one('SELECT id, role FROM users WHERE mobile = ?', input.mobile);
      requireValue(!existing || existing.role === 'worker', '该手机号已用于其他角色，请使用独立的维修账号');
      const target: AuditTarget = { type: 'worker', id: existing ? String(existing.id) : randomUUID() };
      const before = this.audit.snapshot(target);
      if (existing) {
        this.checkWorkforceRevision(String(existing.id), input.revision);
        this.store.run('UPDATE users SET nickName = ?, workforceRevision=workforceRevision+1 WHERE id = ?', input.nickName, String(existing.id));
      }
      else this.store.run("INSERT INTO users(id, mobile, nickName, role) VALUES (?, ?, ?, 'worker')", target.id, input.mobile, input.nickName);
      this.workforceChanged();
      this.audit.append({ actorId, action: 'worker.save' }, target, before);
      return this.workers();
    });
  }

  saveLeave(workerId: string, raw: unknown, actorId: string) {
    this.requireRole(actorId, 'admin');
    const input = z.object({ revision, date: leaveDate, hour: leaveHour, reason: note.default(''), preview: z.boolean().default(false) }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.revision);
      const worker = readWorkforce(this.store).find(item => item.id === workerId)!;
      const impact = this.calculateImpact({ ...worker, leaves: [...worker.leaves, { date: input.date, hour: input.hour }] });
      if (input.preview) return this.previewImpact(impact);
      const target: AuditTarget = { type: 'worker', id: workerId };
      const before = this.audit.snapshot(target);
      this.store.run('INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,?,?,?) ON CONFLICT(workerId,date,hour) DO UPDATE SET reason=excluded.reason', workerId, input.date, input.hour, input.reason);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      this.saveImpact(impact);
      this.workforceChanged();
      this.audit.append({ actorId, action: 'worker.leave.save' }, target, before);
      return this.workers();
    });
  }

  workerSkills(workerId: string) {
    this.requireRole(workerId, 'worker');
    const worker = this.workers().find(item => item.id === workerId)!;
    return { skills: worker.skills, workforceRevision: Number(worker.revision), skillChange: worker.skillChange };
  }

  saveSkills(workerId: string, raw: unknown, actorId = workerId) {
    this.requireRole(actorId, actorId === workerId ? 'worker' : 'admin');
    const input = z.object({ workforceRevision: revision, skills: z.array(z.enum(['plumbing', 'electrical', 'doors'])).max(3),
      preview: z.boolean().default(false), previewToken: z.string().uuid().optional() }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.workforceRevision);
      const worker = readWorkforce(this.store).find(item => item.id === workerId)!;
      const skills = [...new Set(input.skills)].sort();
      if (actorId !== workerId) requireValue(skills.every(skill => worker.skills.includes(skill)), '物业只能撤销已登记技能');
      // 本次保存会写入审计记录；预览也按保存后的已登记状态计算。
      const impact = this.calculateImpact({ ...worker, skills, skillsKnown: true });
      const preview = this.skillPreviewState(impact, workerId, actorId, input.workforceRevision, skills);
      if (input.preview) return this.issueSkillPreview(impact, preview);
      if (worker.skills.some(skill => !skills.includes(skill))) {
        const previous = input.previewToken ? this.skillPreviews.get(input.previewToken) : undefined;
        const belongsToRequest = previous && previous.actorId === actorId && previous.workerId === workerId
          && previous.revision === input.workforceRevision && previous.skills === preview.skills;
        if (!belongsToRequest || previous.expiresAt <= this.now() || previous.signature !== preview.signature) {
          const latest = this.issueSkillPreview(impact, preview);
          const changed = belongsToRequest ? previous.orders.flatMap<Record<string, unknown>>(before => {
            const record = impact.records.find(item => item.id === before.id);
            if (!record) return [{ repairItemName: '工单已移除', status: -1, assignmentChanged: true }];
            if (Number(record.revision ?? 0) === before.revision && Number(record.status) === before.status
              && String(record.workerId ?? '') === before.workerId) return [];
            const { id: _id, ...summary } = workforceOrderSummary(record);
            return [{ ...summary, status: Number(record.status),
              assignmentChanged: String(record.workerId ?? '') !== before.workerId }];
          }) : [];
          throw new ApiError(200, 40901, '工单影响已更新，请查看最新结果后重新确认', { ...latest, changed });
        }
      }
      const target: AuditTarget = { type: 'worker', id: workerId };
      const before = this.audit.snapshot(target);
      this.store.run('DELETE FROM worker_skills WHERE workerId=?', workerId);
      for (const skill of skills) this.store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', workerId, skill);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      const actor = this.store.one('SELECT nickName FROM users WHERE id=?', actorId)!;
      this.store.run('INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES (?,?,?,?) ON CONFLICT(workerId) DO UPDATE SET actorId=excluded.actorId,actorName=excluded.actorName,changedAt=excluded.changedAt',
        workerId, actorId, String(actor.nickName), new Date(this.now()).toISOString());
      this.saveImpact(impact);
      this.workforceChanged();
      this.audit.append({ actorId, action: 'worker.skills' }, target, before);
      if (input.previewToken) this.skillPreviews.delete(input.previewToken);
      return this.workerSkills(workerId);
    });
  }

  private calculateImpact(worker: ReturnType<typeof readWorkforce>[number]) {
    const rows = this.store.db.prepare('SELECT payload FROM repairs WHERE json_valid(payload)').all();
    const records = rows.map(row => JSON.parse(String(row.payload)) as RecordData)
      .filter(record => record && typeof record === 'object' && !Array.isArray(record));
    const impact = workforceImpact(records, worker, this.now());
    const replacements = new Map(impact.returned.map(record => [record.id, record]));
    const workers = readWorkforce(this.store);
    const before = new Map(new StaffingContext(workers, records).shortages().map(item => [item.slot, item.shortage]));
    const context = new StaffingContext(workers.map(current => current.id === worker.id ? worker : current),
      records.map(record => replacements.get(record.id) ?? record));
    const propertyIds = new Set(impact.property.map(record => record.id));
    for (const record of impact.returned) {
      if (!propertyIds.has(record.id) && inRepairPool(record) && !context.eligible(record).length) {
        impact.property.push(record);
        propertyIds.add(record.id);
      }
    }
    return { ...impact, records, shortages: context.shortages().filter(item => item.shortage > (before.get(item.slot) ?? 0)) };
  }

  private skillPreviewState(impact: ReturnType<WorkflowService['calculateImpact']>, workerId: string,
    actorId: string, workforceRevision: number, skills: string[]): SkillPreview {
    const ids = (rows: readonly RecordData[]) => rows.map(row => row.id).sort();
    const affected = new Set([...ids(impact.returned), ...ids(impact.property),
      ...impact.shortages.flatMap(item => item.orders.map(row => row.id))]);
    const orders = impact.records.filter(row => affected.has(row.id)).map(row => ({
      id: row.id, revision: Number(row.revision ?? 0), workerId: String(row.workerId ?? ''), status: Number(row.status),
    })).sort((a, b) => a.id.localeCompare(b.id));
    const signature = createHash('sha256').update(JSON.stringify({ orders,
      returned: ids(impact.returned), property: ids(impact.property), shortages: impact.shortages,
    })).digest('hex');
    return { workerId, actorId, revision: workforceRevision, skills: skills.join(','), signature, orders,
      expiresAt: this.now() + 15 * 60_000 };
  }

  private issueSkillPreview(impact: ReturnType<WorkflowService['calculateImpact']>, preview: SkillPreview) {
    for (const [token, item] of this.skillPreviews) {
      if (item.expiresAt <= this.now()) this.skillPreviews.delete(token);
    }
    let actorTokens = [...this.skillPreviews.entries()]
      .filter(([, item]) => item.actorId === preview.actorId);
    while (actorTokens.length >= SKILL_PREVIEW_ACTOR_LIMIT) {
      const oldest = actorTokens.shift();
      if (oldest) this.skillPreviews.delete(oldest[0]);
    }
    if (this.skillPreviews.size >= SKILL_PREVIEW_TOTAL_LIMIT) {
      throw new ApiError(429, 42901, '技能预览凭据已达全站上限，请稍后重试');
    }
    const previewToken = randomUUID();
    this.skillPreviews.set(previewToken, preview);
    return { ...this.previewImpact(impact, preview.actorId === preview.workerId), previewToken };
  }

  private previewImpact(impact: ReturnType<WorkflowService['calculateImpact']>, hideIds = false) {
    const summary = (record: RecordData) => {
      const value = workforceOrderSummary(record);
      if (!hideIds) return value;
      const { id: _id, ...visible } = value;
      return visible;
    };
    return { returned: impact.returned.map(summary), property: impact.property.map(summary),
      shortages: impact.shortages.map(item => ({ ...item, orders: item.orders.map(summary) })) };
  }

  private saveImpact(impact: ReturnType<typeof workforceImpact>) {
    for (const record of impact.returned) {
      const owner = this.store.one('SELECT userId FROM repairs WHERE id=?', record.id)!;
      record.revision = Number(record.revision ?? 0) + 1;
      this.store.save('repairs', String(owner.userId), record, true);
    }
  }

  removeLeave(workerId: string, raw: unknown, actorId: string) {
    this.requireRole(actorId, 'admin');
    const input = z.object({ revision, date: leaveDate, hour: leaveHour }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.revision);
      const target: AuditTarget = { type: 'worker', id: workerId };
      const before = this.audit.snapshot(target);
      this.store.run('DELETE FROM worker_leaves WHERE workerId=? AND date=? AND hour=?', workerId, input.date, input.hour);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      this.workforceChanged();
      this.audit.append({ actorId, action: 'worker.leave.remove' }, target, before);
      return this.workers();
    });
  }

  private checkWorkforceRevision(workerId: string, expected: number | undefined) {
    const worker = this.store.one("SELECT workforceRevision,disabledAt FROM users WHERE id=? AND role='worker'", workerId);
    if (!worker) throw new ApiError(404, 40400, '维修人员不存在');
    requireValue(Number(worker.disabledAt) === 0, '该账号已停用，请先恢复使用');
    if (expected !== Number(worker.workforceRevision)) throw new ApiError(409, 40900, '人员安排已更新，请刷新后再操作');
  }

  private checkHouseReviewData(reviewData: unknown) {
    // 定义审核决定的规则：只允许通过（approve）或打回（reject）。
    const reviewDecisionRule = z.enum(['approve', 'reject']);
    const houseReviewRules = z.object({
      revision,
      decision: reviewDecisionRule,
      reason: note.default(''),
    }).strict();

    // 按上面的规则检查提交的数据，不符合规则就报错停止。
    const reviewDataToCheck = houseReviewRules.parse(reviewData);
    if (reviewDataToCheck.decision === 'reject') {
      requireValue(reviewDataToCheck.reason.length > 0, '请填写打回原因');
    }
    return reviewDataToCheck;
  }

  private saveReview(ownerUserId: string, reviewedHouse: RecordData) {
    this.store.save('rooms', ownerUserId, reviewedHouse, true);
  }

  reviewHouse(houseId: string, reviewerUserId: string, reviewData: unknown) {
    this.requireRole(reviewerUserId, 'admin');
    // 提交格式和必填内容检查通过，才会拿到结果；检查失败会报错停止。
    const passedCheckData = this.checkHouseReviewData(reviewData);
    return this.store.transaction(() => {
      const storedHouseData = this.store.one('SELECT userId, payload FROM rooms WHERE id = ?', houseId);
      if (!storedHouseData) throw new ApiError(404, 40400, '记录不存在');
      const ownerUserId = String(storedHouseData.userId);
      const houseToReview = JSON.parse(String(storedHouseData.payload)) as RecordData;
      const target: AuditTarget = { type: 'room', id: houseId };
      const before = this.audit.snapshot(target);
      const currentRevision = Number(houseToReview.revision ?? 0);
      const submittedRevision = passedCheckData.revision;
      if (currentRevision !== submittedRevision) {
        throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      }
      if (houseToReview.status !== 1) {
        throw new ApiError(409, 40900, '这份房屋资料已审核，请刷新查看最新状态');
      }
      let reviewStatus = 2; // 已通过
      let rejectionReason = '';
      if (passedCheckData.decision === 'reject') {
        reviewStatus = 3; // 已打回
        rejectionReason = passedCheckData.reason;
      }
      // 资料编辑与审核共用版本，审核前打开的住户表单也必须重新加载。
      const reviewedHouse = {
        ...houseToReview,
        status: reviewStatus,
        reviewReason: rejectionReason,
        reviewedAt: new Date(this.now()).toISOString(),
        reviewedBy: reviewerUserId,
        revision: currentRevision + 1,
      };
      this.saveReview(ownerUserId, reviewedHouse);
      this.audit.append({ actorId: reviewerUserId, action: 'room.review' }, target, before);
      return reviewedHouse;
    });
  }
}
